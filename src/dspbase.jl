# This file was formerly a part of Julia. License is MIT: https://julialang.org/license

import Base.trailingsize
import Compat.LinearAlgebra.BLAS

_zerosi(b,a,T) = zeros(promote_type(eltype(b), eltype(a), T), max(length(a), length(b))-1)

"""
    filt(b, a, x, [si])

Apply filter described by vectors `a` and `b` to vector `x`, with an optional initial filter
state vector `si` (defaults to zeros).
"""
function filt(b::Union{AbstractVector, Number}, a::Union{AbstractVector, Number},
              x::AbstractArray{T}, si::AbstractArray{S} = _zerosi(b,a,T)) where {T,S}
    filt!(Array{promote_type(eltype(b), eltype(a), T, S)}(undef, size(x)), b, a, x, si)
end

# in-place filtering: returns results in the out argument, which may shadow x
# (and does so by default)

"""
    filt!(out, b, a, x, [si])

Same as [`filt`](@ref) but writes the result into the `out` argument, which may
alias the input `x` to modify it in-place.
"""
function filt!(out::AbstractArray, b::Union{AbstractVector, Number}, a::Union{AbstractVector, Number},
               x::AbstractArray{T}, si::AbstractArray{S,N} = _zerosi(b,a,T)) where {T,S,N}
    isempty(b) && throw(ArgumentError("filter vector b must be non-empty"))
    isempty(a) && throw(ArgumentError("filter vector a must be non-empty"))
    a[1] == 0  && throw(ArgumentError("filter vector a[1] must be nonzero"))
    if size(x) != size(out)
        throw(ArgumentError("output size $(size(out)) must match input size $(size(x))"))
    end

    as = length(a)
    bs = length(b)
    sz = max(as, bs)
    silen = sz - 1
    ncols = trailingsize(x,2)

    if size(si, 1) != silen
        throw(ArgumentError("initial state vector si must have max(length(a),length(b))-1 rows"))
    end
    if N > 1 && trailingsize(si,2) != ncols
        throw(ArgumentError("initial state vector si must be a vector or have the same number of columns as x"))
    end

    size(x,1) == 0 && return out
    sz == 1 && return mul!(out, x, b[1]/a[1]) # Simple scaling without memory

    # Filter coefficient normalization
    if a[1] != 1
        norml = a[1]
        a = a ./ norml
        b = b ./ norml
    end
    # Pad the coefficients with zeros if needed
    bs<sz   && (b = copyto!(zeros(eltype(b), sz), b))
    1<as<sz && (a = copyto!(zeros(eltype(a), sz), a))

    initial_si = si
    for col = 1:ncols
        # Reset the filter state
        si = initial_si[:, N > 1 ? col : 1]
        if as > 1
            _filt_iir!(out, b, a, x, si, col)
        else
            _filt_fir!(out, b, x, si, col)
        end
    end
    return out
end

function _filt_iir!(out, b, a, x, si, col)
    silen = length(si)
    @inbounds for i=1:size(x, 1)
        xi = x[i,col]
        val = si[1] + b[1]*xi
        for j=1:(silen-1)
            si[j] = si[j+1] + b[j+1]*xi - a[j+1]*val
        end
        si[silen] = b[silen+1]*xi - a[silen+1]*val
        out[i,col] = val
    end
end

function _filt_fir!(out, b, x, si, col)
    silen = length(si)
    @inbounds for i=1:size(x, 1)
        xi = x[i,col]
        val = si[1] + b[1]*xi
        for j=1:(silen-1)
            si[j] = si[j+1] + b[j+1]*xi
        end
        si[silen] = b[silen+1]*xi
        out[i,col] = val
    end
end

"""
    deconv(b,a) -> c

Construct vector `c` such that `b = conv(a,c) + r`.
Equivalent to polynomial division.
"""
function deconv(b::StridedVector{T}, a::StridedVector{T}) where T
    lb = size(b,1)
    la = size(a,1)
    if lb < la
        return [zero(T)]
    end
    lx = lb-la+1
    x = zeros(T, lx)
    x[1] = 1
    filt(b, a, x)
end

"""
    conv(u,v)

Convolution of two Arrays using FFT algorithm
"""
function conv(A::StridedArray{T,N}, B::StridedArray{T, N}) where T where N
    dims = 1:N
    ftshape = Tuple(size(A, i) + size(B, i) - 1 for i in dims)
    At = zeros(T, ftshape)
    At[[1:size(A, i) for i in dims]...] = A
    Bt = zeros(T, ftshape)
    Bt[[1:size(B, i) for i in dims]...] = B
    p = plan_fft(At, dims)
    C = ifft((p * At) .* (p * Bt), dims)
    # TODO: this is awkward
    if T <: Real
        C = real(C)
    end
    if T <: Int || T<:Complex{Int}
        C = round.(C)
    end
    return convert(typeof(A), C)
end

function conv(A::StridedArray{T}, B::StridedArray{T}) where T
    maxnd = max(ndims(A), ndims(B))
    return conv(cat(A, dims=maxnd), cat(B, dims=maxnd))
end


# 1D-conv left separate as temporary measure until #263 is addressed
function conv(u::StridedVector{T}, v::StridedVector{T}) where T<:BLAS.BlasFloat
    nu = length(u)
    nv = length(v)
    n = nu + nv - 1
    np2 = n > 1024 ? nextprod([2,3,5], n) : nextpow(2, n)
    upad = [u; zeros(T, np2 - nu)]
    vpad = [v; zeros(T, np2 - nv)]
    if T <: Real
        p = plan_rfft(upad)
        y = irfft((p*upad).*(p*vpad), np2)
    else
        p = plan_fft!(upad)
        y = ifft!((p*upad).*(p*vpad))
    end
    return y[1:n]
end
conv(u::StridedVector{T}, v::StridedVector{T}) where {T<:Integer} = round.(Int, conv(float(u), float(v)))
conv(u::StridedVector{<:Integer}, v::StridedVector{<:BLAS.BlasFloat}) = conv(float(u), v)
conv(u::StridedVector{<:BLAS.BlasFloat}, v::StridedVector{<:Integer}) = conv(u, float(v))


"""
    xcorr(u,v)

Compute the cross-correlation of two vectors.
"""
function xcorr(u, v)
    su = size(u,1); sv = size(v,1)
    if su < sv
        u = [u;zeros(eltype(u),sv-su)]
    elseif sv < su
        v = [v;zeros(eltype(v),su-sv)]
    end
    conv(u, Compat.reverse(conj(v), dims=1))
end
