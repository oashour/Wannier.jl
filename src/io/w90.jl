using Printf: @printf, @sprintf
using Dates: now
import DelimitedFiles as Dlm
import LinearAlgebra as LA

function read_win(filename::String)
    @info "Reading win file: $filename"
    io = open(filename)

    # The win file uses "num_wann", so I keep it as is, and not using "n_wann".
    num_wann = missing
    num_bands = missing
    mp_grid = missing
    unit_cell = missing
    kpoints = missing
    kpoint_path = missing

    parse_array(line::String) = map(x -> parse(Float64, x), split(line))
    read_array(f::IOStream) = parse_array(readline(f))

    while !eof(io)
        line = readline(io)
        # handle case insensitive win files (relic of Fortran)
        line = strip(lowercase(line))

        line = replace(line, "=" => " ", ":" => " ", "," => " ")

        i = findfirst(r"!|#", line)
        if i != nothing
            line = strip(line[1:(i.start - 1)])
        end

        if isempty(line)
            continue
        end

        if occursin("mp_grid", line)
            mp_grid = map(x -> parse(Int, x), split(line)[2:4])
            n_kpts = prod(mp_grid)
        elseif occursin("num_bands", line)
            num_bands = parse(Int, split(line)[2])
        elseif occursin("num_wann", line)
            num_wann = parse(Int, split(line)[2])
        elseif occursin(r"begin\s+unit_cell_cart", line)
            unit_cell = zeros(Float64, 3, 3)
            line = readline(io)
            unit = strip(lowercase(line))
            if !startswith(unit, "b") && !startswith(unit, "a")
                unit = "ang"
            else
                line = readline(io)
            end
            for i in 1:3
                # in win file, each line is a lattice vector, here it is stored as column vec
                unit_cell[:, i] = parse_array(line)
                line = readline(io)
            end
            if startswith(unit, "b")
                # convert to angstrom
                unit_cell .*= Bohr
            end
            unit_cell = Mat3{Float64}(unit_cell)
        elseif occursin(r"begin\s+kpoints", line)
            line = strip(readline(io))
            # kpoints block might be defined before mp_grid!
            # I need to read all lines and get n_kpts
            lines = Vector{String}()
            while !occursin(r"end\s+kpoints", line)
                push!(lines, line)
                line = strip(readline(io))
            end

            n_kpts = length(lines)
            kpoints = Matrix{Float64}(undef, 3, n_kpts)
            for i in 1:n_kpts
                # There might be weight at 4th column, but we don't use it.
                kpoints[:, i] = parse_array(lines[i])[1:3]
            end
        elseif occursin(r"begin\skpoint_path", line)
            kpoint_path = Kpath{Float64}()

            line = strip(readline(io))
            while !occursin(r"end\s+kpoint_path", line)
                l = split(line)
                length(l) != 8 && error("Invalid kpoint_path line: $line")

                start_label = String(l[1])
                start_kpt = Vec3{Float64}(parse.(Float64, l[2:4]))
                end_label = String(l[5])
                end_kpt = Vec3{Float64}(parse.(Float64, l[6:8]))
                push!(kpoint_path, (start_label => start_kpt, end_label => end_kpt))

                line = strip(readline(io))
            end
        end
    end
    close(io)

    ismissing(num_wann) && error("num_wann not found in win file")
    num_wann <= 0 && error("num_wann must be positive")

    ismissing(num_bands) && (num_bands = num_wann)
    num_bands <= 0 && error("num_bands must be positive")

    any(i -> i <= 0, mp_grid) && error("mp_grid must be positive")

    any(x -> ismissing(x), unit_cell) && error("unit_cell not found in win file")

    println("  num_wann  = ", num_wann)
    println("  num_bands = ", num_bands)
    @printf("  mp_grid   = %d %d %d\n", mp_grid...)
    println()

    return (
        num_wann=num_wann,
        num_bands=num_bands,
        mp_grid=mp_grid,
        kpoints=kpoints,
        unit_cell=unit_cell,
        kpoint_path=kpoint_path,
    )
end

function read_mmn(filename::String)
    @info "Reading mmn file: $filename"
    io = open(filename)

    # skip header
    header = readline(io)

    line = readline(io)
    n_bands, n_kpts, n_bvecs = map(x -> parse(Int64, x), split(line))

    # overlap matrix
    M = zeros(ComplexF64, n_bands, n_bands, n_bvecs, n_kpts)
    # for each point, list of neighbors, (K) representation
    kpb_k = zeros(Int64, n_bvecs, n_kpts)
    kpb_b = zeros(Int64, 3, n_bvecs, n_kpts)

    while !eof(io)
        for ib in 1:n_bvecs
            line = readline(io)
            arr = split(line)
            k = parse(Int64, arr[1])
            kpb_k[ib, k] = parse(Int64, arr[2])
            kpb_b[:, ib, k] = map(x -> parse(Int64, x), arr[3:5])
            for n in 1:n_bands
                for m in 1:n_bands
                    line = readline(io)
                    arr = split(line)
                    o = parse(Float64, arr[1]) + im * parse(Float64, arr[2])
                    M[m, n, ib, k] = o
                end
            end
        end
    end

    @assert !any(isnan.(M))

    close(io)

    println("  header  = ", header)
    println("  n_bands = ", n_bands)
    println("  n_bvecs = ", n_bvecs)
    println("  n_kpts  = ", n_kpts)
    println()

    return M, kpb_k, kpb_b
end

"""
Output mmn file
"""
function write_mmn(
    filename::String,
    M::Array{ComplexF64,4},
    kpb_k::Matrix{Int},
    kpb_b::Array{Int,3},
    header::String,
)
    n_bands, _, n_bvecs, n_kpts = size(M)
    n_bands != size(M, 2) && error("M must be n_bands x n_bands x n_bvecs x n_kpts")

    size(kpb_k) != (n_bvecs, n_kpts) && error("kpb_k has wrong size")
    size(kpb_b) != (3, n_bvecs, n_kpts) && error("kpb_b has wrong size")

    open(filename, "w") do io
        header = strip(header)
        write(io, header, "\n")

        @printf(io, "    %d   %d    %d \n", n_bands, n_kpts, n_bvecs)

        for ik in 1:n_kpts
            for ib in 1:n_bvecs
                @printf(io, "%d %d %d %d %d\n", ik, kpb_k[ib, ik], kpb_b[:, ib, ik]...)

                for n in 1:n_bands
                    for m in 1:n_bands
                        o = M[m, n, ib, ik]
                        @printf(io, "  %16.12f  %16.12f\n", real(o), imag(o))
                    end
                end
            end
        end
    end

    @info "Written to file: $(filename)"
    println()

    return nothing
end

"""
Output mmn file
"""
function write_mmn(
    filename::String, M::Array{ComplexF64,4}, kpb_k::Matrix{Int}, kpb_b::Array{Int,3}
)
    header = @sprintf "Created by Wannier.jl %s" string(now())
    return write_mmn(filename, M, kpb_k, kpb_b, header)
end

function read_amn(filename::String)
    @info "Reading $filename"

    io = open("$filename")

    header = readline(io)

    arr = split(readline(io))
    n_bands, n_kpts, n_wann = parse.(Int64, arr[1:3])

    A = zeros(ComplexF64, n_bands, n_wann, n_kpts)

    while !eof(io)
        line = readline(io)
        arr = split(line)

        m, n, k = parse.(Int64, arr[1:3])

        a = parse(Float64, arr[4]) + im * parse(Float64, arr[5])
        A[m, n, k] = a
    end

    close(io)

    println("  header  = ", header)
    println("  n_bands = ", n_bands)
    println("  n_wann  = ", n_wann)
    println("  n_kpts  = ", n_kpts)
    println()

    return A
end

"""
Output amn file
"""
function write_amn(filename::String, A::Array{ComplexF64,3}, header::String)
    n_bands, n_wann, n_kpts = size(A)

    io = open(filename, "w")

    header = strip(header)
    write(io, header, "\n")

    @printf(io, "%3d %4d %4d\n", n_bands, n_kpts, n_wann)

    for ik in 1:n_kpts
        for iw in 1:n_wann
            for ib in 1:n_bands
                a = A[ib, iw, ik]
                @printf(io, "%5d %4d %4d  %16.12f  %16.12f\n", ib, iw, ik, real(a), imag(a))
            end
        end
    end

    close(io)

    @info "Written to file: $(filename)"
    println()

    return nothing
end

"""
Output amn file
"""
function write_amn(filename::String, A::Array{ComplexF64,3})
    header = @sprintf "Created by Wannier.jl %s" string(now())
    return write_amn(filename, A, header)
end

function read_eig(filename::String)
    @info "Reading $filename"

    lines = open(filename) do io
        readlines(io)
    end

    n_lines = length(lines)
    idx_b = zeros(Int, n_lines)
    idx_k = zeros(Int, n_lines)
    eig = zeros(Float64, n_lines)

    for i in 1:n_lines
        arr = split(lines[i])
        idx_b[i] = parse(Int, arr[1])
        idx_k[i] = parse(Int, arr[2])
        eig[i] = parse(Float64, arr[3])
    end

    # find unique elements
    n_bands = length(Set(idx_b))
    n_kpts = length(Set(idx_k))
    E = reshape(eig, (n_bands, n_kpts))

    # check eigenvalues should be in order
    # some times there are small noise
    round_digits(x) = round(x; digits=9)
    for ik in 1:n_kpts
        @assert issorted(E[:, ik], by=round_digits) display(ik) display(E[:, ik])
    end

    println("  n_bands = ", n_bands)
    println("  n_kpts  = ", n_kpts)
    println()

    return E
end

"""
Write eig file
"""
function write_eig(filename::String, E::Matrix{T}) where {T<:Real}
    n_bands, n_kpts = size(E)

    open(filename, "w") do io
        for ik in 1:n_kpts
            for ib in 1:n_bands
                @printf(io, "%5d%5d%18.12f\n", ib, ik, E[ib, ik])
            end
        end
    end

    @info "Written to file: $(filename)"
    println()

    return nothing
end

@doc raw"""
read win, and optionally amn, mmn, eig
"""
function read_seedname(seedname::String; amn::Bool=true, mmn::Bool=true, eig::Bool=true)
    win = read_win("$seedname.win")

    n_bands = win.num_bands
    n_wann = win.num_wann
    kpoints = win.kpoints
    kgrid = Vec3{Int}(win.mp_grid)
    n_kpts = prod(kgrid)

    lattice = win.unit_cell
    recip_lattice = get_recip_lattice(lattice)

    bvectors = get_bvectors(kpoints, recip_lattice)
    n_bvecs = bvectors.n_bvecs

    if mmn
        M, kpb_k_mmn, kpb_b_mmn = read_mmn("$seedname.mmn")

        # check consistency for mmn
        n_bands != size(M)[1] && error("n_bands != size(M)[1]")
        n_bvecs != size(M)[3] && error("n_bvecs != size(M)[3]")
        n_kpts != size(M)[4] && error("n_kpts != size(M)[4]")
        bvectors.kpb_k != kpb_k_mmn && error("kpb_k != kpb_k from mmn file")
        bvectors.kpb_b != kpb_b_mmn && error("kpb_b != kpb_b from mmn file")
    else
        M = zeros(ComplexF64, n_bands, n_bands, n_bvecs, n_kpts)
    end

    if amn
        A = read_amn("$seedname.amn")
        n_bands != size(A)[1] && error("n_bands != size(A)[1]")
        n_wann != size(A)[2] && error("n_wann != size(A)[2]")
        n_kpts != size(A)[3] && error("n_kpts != size(A)[3]")
    else
        A = zeros(ComplexF64, n_bands, n_wann, n_kpts)
        for n in 1:n_wann
            A[n, n, :] .= 1
        end
    end

    if eig
        E = read_eig("$seedname.eig")
        n_bands != size(E)[1] && error("n_bands != size(E)[1]")
        n_kpts != size(E)[2] && error("n_kpts != size(E)[2]")
    else
        E = zeros(Float64, n_bands, n_kpts)
    end

    frozen_bands = falses(n_bands, n_kpts)

    return Model(lattice, kgrid, kpoints, bvectors, frozen_bands, M, A, E)
end

function read_nnkp(filename::String)
    @info "Reading nnkp file: $filename"

    io = open(filename)

    read_array(type::Type) = map(x -> parse(type, x), split(readline(io)))

    real_lattice = zeros(Float64, 3, 3)
    recip_lattice = similar(real_lattice)

    n_kpts = nothing
    n_bvecs = nothing
    kpoints = nothing
    kpb_k = nothing
    kpb_b = nothing

    while !eof(io)
        line = readline(io)

        if occursin("begin real_lattice", line)
            for i in 1:3
                real_lattice[:, i] = read_array(Float64)
            end

            line = strip(readline(io))
            line != "end real_lattice" && error("expected end real_lattice")

        elseif occursin("begin recip_lattice", line)
            for i in 1:3
                recip_lattice[:, i] = read_array(Float64)
            end

            line = strip(readline(io))
            line != "end recip_lattice" && error("expected end recip_lattice")

        elseif occursin("begin kpoints", line)
            n_kpts = parse(Int, readline(io))
            kpoints = zeros(Float64, 3, n_kpts)

            for i in 1:n_kpts
                kpoints[:, i] = read_array(Float64)
            end

            line = strip(readline(io))
            line != "end kpoints" && error("expected end kpoints")

        elseif occursin("begin nnkpts", line)
            n_kpts === nothing && error("no kpoints block before nnkpts block?")

            n_bvecs = parse(Int, readline(io))
            kpb_k = zeros(Int, n_bvecs, n_kpts)
            kpb_b = zeros(Int, 3, n_bvecs, n_kpts)

            for ik in 1:n_kpts
                for ib in 1:n_bvecs
                    arr = read_array(Int)
                    ik != arr[1] && error("expected ik = $ik, got $(arr[1])")
                    kpb_k[ib, ik] = arr[2]
                    kpb_b[:, ib, ik] = arr[3:end]
                end
            end

            line = strip(readline(io))
            line != "end nnkpts" && error("expected end nnkpts")
        end
    end
    close(io)

    @info "$filename OK" n_kpts n_bvecs
    println()

    bvectors = Matrix{Float64}(undef, 3, n_bvecs)
    fill!(bvectors, NaN)

    # Generate bvectors from 1st kpoint, in Cartesian coordinates
    ik = 1
    for ib in 1:n_bvecs
        ik2 = kpb_k[ib, ik]
        b = kpb_b[:, ib, ik]
        bvec = kpoints[:, ik2] + b - kpoints[:, ik]
        bvectors[:, ib] = recip_lattice * bvec
    end

    weights = zeros(Float64, n_bvecs)
    fill!(weights, NaN)

    return BVectors(Mat3{Float64}(recip_lattice), kpoints, bvectors, weights, kpb_k, kpb_b)
end

"""
read si_band.dat  si_band.kpt  si_band.labelinfo.dat
"""
function read_w90_bands(seedname::String)
    kpoints = Dlm.readdlm("$(seedname)_band.kpt", Float64; skipstart=1)
    # remove weights, then transpose, last idx is kpt
    kpoints = Matrix(transpose(kpoints[:, 1:3]))
    n_kpts = size(kpoints, 2)

    dat = Dlm.readdlm("$(seedname)_band.dat", Float64)
    x = reshape(dat[:, 1], n_kpts, :)[:, 1]
    E = reshape(dat[:, 2], n_kpts, :)
    E = Matrix(transpose(E))
    n_bands = size(E, 1)

    io = open("$(seedname)_band.labelinfo.dat")
    labels = readlines(io)
    close(io)

    n_symm = length(labels)
    symm_idx = Vector{Int}(undef, n_symm)
    symm_label = Vector{String}(undef, n_symm)
    for (i, line) in enumerate(labels)
        lab, idx = split(line)[1:2]
        symm_idx[i] = parse(Int, idx)
        symm_label[i] = lab
    end

    return (kpoints=kpoints, E=E, x=x, symm_idx=symm_idx, symm_label=symm_label)
end

"""
write si_band.dat  si_band.kpt  si_band.labelinfo.dat
"""
function write_w90_bands(
    seedname::String,
    kpoints::AbstractMatrix{T},
    E::AbstractMatrix{T},
    x::AbstractVector{T},
    symm_idx::AbstractVector{Int},
    symm_label::AbstractVector{String},
) where {T<:Real}
    n_kpts = size(kpoints, 2)
    size(kpoints, 1) != 3 && error("kpoints must be 3 x n_kpts")

    n_bands = size(E, 1)
    size(E, 2) != n_kpts && error("E must be n_bands x n_kpts")

    length(x) != n_kpts && error("x must be n_kpts")

    n_symm = length(symm_idx)
    n_symm != length(symm_label) && error("symm_idx and symm_label must be same length")

    filename = "$(seedname)_band.kpt"
    open(filename, "w") do io
        @printf(io, "       %5d\n", n_kpts)
        for ik in 1:n_kpts
            @printf(io, "  %10.6f  %10.6f  %10.6f   1.0\n", kpoints[:, ik]...)
        end
    end
    @info "Written to $filename"

    filename = "$(seedname)_band.dat"
    open(filename, "w") do io
        for ib in 1:n_bands
            for ik in 1:n_kpts
                @printf(io, " %15.8E %15.8E\n", x[ik], E[ib, ik])
            end
        end
    end
    @info "Written to $filename"

    filename = "$(seedname)_band.labelinfo.dat"
    open(filename, "w") do io
        for i in 1:n_symm
            idx = symm_idx[i]
            @printf(
                io,
                "%2s %31d %20.10f %17.10f %17.10f %17.10f\n",
                symm_label[i],
                idx,
                x[i],
                kpoints[:, idx]...
            )
        end
    end
    @info "Written to $filename"
end

function read_wout(filename::String)
    io = open(filename)

    start_cell = "Lattice Vectors ("
    start_atom = "|   Site       Fractional Coordinate          Cartesian Coordinate"
    end_atom = "*----------------------------------------------------------------------------*"
    start_finalstate = "Final State"
    end_finalstate = "Sum of centres and spreads"

    ang_unit = false
    unit_cell = nothing
    atoms = nothing
    centers = nothing
    spreads = nothing

    while !eof(io)
        line = strip(readline(io))

        if occursin("|  Length Unit", line)
            @assert occursin("Ang", line)
            ang_unit = true
            continue
        end

        if occursin(start_cell, line)
            @assert occursin("Ang", line)
            unit_cell = zeros(Float64, 3, 3)

            line = split(strip(readline(io)))
            @assert line[1] == "a_1"
            unit_cell[:, 1] = parse.(Float64, line[2:end])

            line = split(strip(readline(io)))
            @assert line[1] == "a_2"
            unit_cell[:, 2] = parse.(Float64, line[2:end])

            line = split(strip(readline(io)))
            @assert line[1] == "a_3"
            unit_cell[:, 3] = parse.(Float64, line[2:end])

            continue
        end

        if occursin(start_atom, line)
            @assert occursin("Ang", line)
            readline(io)

            lines = Vector{String}()
            line = strip(readline(io))
            while line != end_atom
                push!(lines, line)
                line = strip(readline(io))
            end

            n_atom = length(lines)
            atoms = zeros(Float64, 3, n_atom)
            for (i, line) in enumerate(lines)
                line = split(line)
                @assert line[1] == "|" line
                # cartesian
                atoms[:, i] = parse.(Float64, line[8:10])
                # Fractional
                atoms[:, i] = parse.(Float64, line[4:6])
            end

            continue
        end

        if occursin(start_finalstate, line)
            lines = Vector{String}()
            line = strip(readline(io))
            while !occursin(end_finalstate, line)
                push!(lines, line)
                line = strip(readline(io))
            end

            n_wann = length(lines)
            centers = zeros(Float64, 3, n_wann)
            spreads = zeros(Float64, n_wann)
            for (i, line) in enumerate(lines)
                line = split(line)
                @assert join(line[1:4], " ") == "WF centre and spread"
                @assert i == parse(Int, line[5])

                x = parse(Float64, replace(line[7], "," => ""))
                y = parse(Float64, replace(line[8], "," => ""))
                z = parse(Float64, replace(line[9], "," => ""))
                s = parse(Float64, line[11])

                centers[:, i] = [x, y, z]
                spreads[i] = s
            end

            continue
        end
    end

    close(io)

    @assert ang_unit

    return (unit_cell=unit_cell, atoms=atoms, centers=centers, spreads=spreads)
end

@doc raw"""
Read UNK file for Bloch wavefunctions.
"""
function read_unk(filename::String)
    @info "Reading unk file:" filename

    io = open(filename)

    line = split(strip(readline(io)))
    n_gx, n_gy, n_gz, ik, n_bands = parse.(Int, line)

    Ψ = zeros(ComplexF64, n_gx, n_gy, n_gz, n_bands)

    for ib in 1:n_bands
        for iz in 1:n_gz
            for iy in 1:n_gy
                for ix in 1:n_gx
                    line = split(strip(readline(io)))
                    v1, v2 = parse.(Float64, line)
                    Ψ[ix, iy, iz, ib] = v1 + im * v2
                end
            end
        end
    end

    close(io)

    println("  n_gx    = ", n_gx)
    println("  n_gy    = ", n_gy)
    println("  n_gz    = ", n_gz)
    println("  ik      = ", ik)
    println("  n_bands = ", n_bands)
    println()

    # ik: at which kpoint? start from 1
    return ik, Ψ
end

@doc raw"""
Write UNK file for Bloch wavefunctions.
    ik: at which kpoint? start from 1
"""
function write_unk(filename::String, ik::Int, Ψ::Array{T,4}) where {T<:Complex}
    @info "Writing unk file:" filename

    n_gx, n_gy, n_gz, n_bands = size(Ψ)

    open(filename, "w") do io
        @printf(io, " %11d %11d %11d %11d %11d\n", n_gx, n_gy, n_gz, ik, n_bands)

        for ib in 1:n_bands
            for iz in 1:n_gz
                for iy in 1:n_gy
                    for ix in 1:n_gx
                        v1 = real(Ψ[ix, iy, iz, ib])
                        v2 = imag(Ψ[ix, iy, iz, ib])
                        @printf(io, " %18.10e %18.10e\n", v1, v2)
                    end
                end
            end
        end
    end

    @info "Written to file: $(filename)"
    println("  n_gx    = ", n_gx)
    println("  n_gy    = ", n_gy)
    println("  n_gz    = ", n_gz)
    println("  ik      = ", ik)
    println("  n_bands = ", n_bands)
    println()

    return nothing
end

"""Struct for storing matrices in seedname.chk file."""
struct Chk{T<:Real}
    header::String

    # These commented variables are written inside chk file,
    # but I move them to the end of the struct and use a constructor
    # to set them according to the shape of the corresponding arrays.

    # n_bands:: Int
    # n_exclude_bands:: Int

    # 1D array, size: num_exclude_bands
    exclude_bands::Vector{Int}

    # 2D array, size: 3 x 3, each column is a lattice vector
    lattice::Mat3{T}

    # 2D array, size: 3 x 3, each column is a lattice vector
    recip_lattice::Mat3{T}

    # n_kpts: Int

    # List of 3 int
    kgrid::Vec3{Int}

    # 2D array, size: 3 x n_kpts, each column is a vector
    kpoints::Matrix{T}

    # n_bvecs:: Int

    # n_wann: int

    checkpoint::String

    have_disentangled::Bool

    # omega invariant
    ΩI::T

    # 2D bool array, size: n_bands x n_kpts
    frozen_bands::Matrix{Bool}

    # 1D int array, size: n_kpts
    # n_dimfrozen:: Vector{Int}

    # u_matrix_opt, 3D array, size: num_bands x num_wann x num_kpts
    Uᵈ::Array{Complex{T},3}

    # u_matrix, 3D array, size: num_wann x num_wann x num_kpts
    U::Array{Complex{T},3}

    # m_matrix, 4D array, size:num_wann x num_wann x n_bvecs x num_kpts
    M::Array{Complex{T},4}

    # wannier_centres, 2D array, size: 3 x num_wann
    r::Matrix{T}

    # wannier_spreads, 1D array, size: num_wann
    ω::Vector{T}

    # these variables are auto-set in constructor
    n_bands::Int
    n_exclude_bands::Int
    n_kpts::Int
    n_bvecs::Int
    n_wann::Int
    n_frozen::Vector{Int}
end

function Chk(
    header::String,
    exclude_bands::Vector{Int},
    lattice::Mat3{T},
    recip_lattice::Mat3{T},
    kgrid::Vec3{Int},
    kpoints::Matrix{T},
    checkpoint::String,
    have_disentangled::Bool,
    ΩI::T,
    frozen_bands::Matrix{Bool},
    Uᵈ::Array{Complex{T},3},
    U::Array{Complex{T},3},
    M::Array{Complex{T},4},
    r::Matrix{T},
    ω::Vector{T},
) where {T<:Real}
    if have_disentangled
        n_bands = size(Uᵈ, 1)
    else
        n_bands = size(U, 1)
    end

    n_exclude_bands = length(exclude_bands)

    n_kpts = size(M, 4)

    n_bvecs = size(M, 3)

    n_wann = size(U, 1)

    if have_disentangled
        n_frozen = zeros(Int, n_kpts)
        for ik in 1:n_kpts
            n_frozen[ik] = count(frozen_bands[:, ik])
        end
    else
        n_frozen = zeros(Int, 0)
    end

    return Chk(
        header,
        exclude_bands,
        lattice,
        recip_lattice,
        kgrid,
        kpoints,
        checkpoint,
        have_disentangled,
        ΩI,
        frozen_bands,
        Uᵈ,
        U,
        M,
        r,
        ω,
        n_bands,
        n_exclude_bands,
        n_kpts,
        n_bvecs,
        n_wann,
        n_frozen,
    )
end

@doc raw"""
Read formatted (not Fortran binary) CHK file.
"""
function read_chk(filename::String)
    if isbinary_file(filename)
        error("$filename is a binary file? Consider using `w90chk2chk.x`?")
    end

    @info "Reading chk file:" filename
    println()

    io = open(filename)

    srline() = strip(readline(io))

    # Read formatted chk file
    header = String(srline())

    n_bands = parse(Int, srline())

    n_exclude_bands = parse(Int, srline())

    exclude_bands = zeros(Int, n_exclude_bands)

    if n_exclude_bands > 0
        for i in 1:n_exclude_bands
            exclude_bands[i] = parse(Int, srline())
        end
    end

    # Each column is a lattice vector
    line = parse.(Float64, split(srline()))
    lattice = Mat3{Float64}(reshape(line, (3, 3)))

    # Each column is a lattice vector
    line = parse.(Float64, split(srline()))
    recip_lattice = Mat3{Float64}(reshape(line, (3, 3)))

    n_kpts = parse(Int, srline())

    kgrid = Vec3{Int}(parse.(Int, split(srline())))

    kpoints = zeros(Float64, 3, n_kpts)
    for ik in 1:n_kpts
        kpoints[:, ik] = parse.(Float64, split(srline()))
    end

    n_bvecs = parse(Int, srline())

    n_wann = parse(Int, srline())

    checkpoint = String(srline())

    # 1 -> True, 0 -> False
    have_disentangled = Bool(parse(Int, srline()))

    if have_disentangled
        # omega_invariant
        ΩI = parse(Float64, srline())

        frozen_bands = zeros(Bool, n_bands, n_kpts)
        for ik in 1:n_kpts
            for ib in 1:n_bands
                # 1 -> True, 0 -> False
                frozen_bands[ib, ik] = Bool(parse(Int, srline()))
            end
        end

        n_frozen = zeros(Int, n_kpts)
        for ik in 1:n_kpts
            n_frozen[ik] = parse(Int, srline())
            @assert n_frozen[ik] == count(frozen_bands[:, ik])
        end

        # u_matrix_opt
        Uᵈ = zeros(ComplexF64, n_bands, n_wann, n_kpts)
        for ik in 1:n_kpts
            for iw in 1:n_wann
                for ib in 1:n_bands
                    vals = parse.(Float64, split(srline()))
                    Uᵈ[ib, iw, ik] = vals[1] + im * vals[2]
                end
            end
        end

    else
        ΩI = -1.0
        frozen_bands = zeros(Bool, 0, 0)
        n_frozen = zeros(Int, 0)
        Uᵈ = zeros(ComplexF64, 0, 0, 0)
    end

    # u_matrix
    U = zeros(ComplexF64, n_wann, n_wann, n_kpts)
    for ik in 1:n_kpts
        for iw in 1:n_wann
            for ib in 1:n_wann
                vals = parse.(Float64, split(srline()))
                U[ib, iw, ik] = vals[1] + im * vals[2]
            end
        end
    end

    #  m_matrix
    M = zeros(ComplexF64, n_wann, n_wann, n_bvecs, n_kpts)
    for ik in 1:n_kpts
        for inn in 1:n_bvecs
            for iw in 1:n_wann
                for ib in 1:n_wann
                    vals = parse.(Float64, split(srline()))
                    M[ib, iw, inn, ik] = vals[1] + im * vals[2]
                end
            end
        end
    end

    # wannier_centres
    r = zeros(Float64, 3, n_wann)
    for iw in 1:n_wann
        r[:, iw] = parse.(Float64, split(srline()))
    end

    # wannier_spreads
    ω = zeros(Float64, n_wann)
    for iw in 1:n_wann
        ω[iw] = parse(Float64, srline())
    end

    close(io)

    return Chk(
        header,
        exclude_bands,
        lattice,
        recip_lattice,
        kgrid,
        kpoints,
        checkpoint,
        have_disentangled,
        ΩI,
        frozen_bands,
        Uᵈ,
        U,
        M,
        r,
        ω,
    )
end
