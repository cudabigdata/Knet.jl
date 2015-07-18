### These were missing from CUDArt:

using CUDArt

import Base: (==), convert, reshape, resize!, copy!, isempty, fill!
import CUDArt: to_host

atype(::CudaArray)=CudaArray

to_host(x)=x                    # so we can use it in general

function (==)(A::CudaArray,B::CudaArray)
    issimilar(A,B) && (to_host(A)==to_host(B))
end

convert{T}(::Type{CudaArray{T}}, a::Array{T})=CudaArray(a)

reshape(a::CudaArray, dims::Dims)=reinterpret(eltype(a), a, dims)
reshape(a::CudaArray, dims::Int...)=reshape(a, dims)

function resize!(a::CudaVector, n::Integer)
    if n < length(a)
        a.dims = (n,)
    elseif n > length(a)
        b = CudaArray(eltype(a), n)
        copy!(b, 1, a, 1, min(n, length(a)))
        free(a.ptr)
        a.ptr = b.ptr
        a.dims = b.dims
    end
    return a
end

# Generalizing low level copy using linear indexing to/from gpu
# arrays:

function copy!(dst::Union(Array,CudaArray), di::Integer, 
               src::Union(Array,CudaArray), si::Integer, 
               n::Integer; stream=null_stream)
    @assert eltype(src) <: eltype(dst) "$(eltype(dst)) != $(eltype(src))"
    if si+n-1 > length(src) || di+n-1 > length(dst) || di < 1 || si < 1
        throw(BoundsError())
    end
    esize = sizeof(eltype(src))
    nbytes = n * esize
    dptr = pointer(dst) + (di-1) * esize
    sptr = pointer(src) + (si-1) * esize
    CUDArt.rt.cudaMemcpyAsync(dptr, sptr, nbytes, CUDArt.cudamemcpykind(dst, src), stream)
    gpusync()
    return dst
end

isempty(a::CudaArray)=(length(a)==0)

# This one has to be defined like this because of a conflict with the CUDArt version:
#fill!(A::AbstractCudaArray,x::Number)=(isempty(A)||cudnnSetTensor(A, x);A)
fill!(A::CudaArray,x::Number)=(isempty(A)||cudnnSetTensor(A, x);A)
