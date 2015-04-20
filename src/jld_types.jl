# Controls whether tuples and non-pointerfree immutables, which Julia
# stores as references, are stored inline in compound types when
# possible. Currently this is problematic because Julia fields of these
# types may be undefined.
const INLINE_TUPLE = false
const INLINE_POINTER_IMMUTABLE = false

const JLD_REF_TYPE = JldDatatype(HDF5Datatype(HDF5.H5T_STD_REF_OBJ, false), 0)
const BUILTIN_TYPES = Set([Symbol, Type, UTF16String, BigFloat, BigInt])
const H5CONVERT_DEFINED = ObjectIdDict()
const JLCONVERT_DEFINED = ObjectIdDict()

## Helper functions

# Holds information about the mapping between a Julia and HDF5 type
immutable JldTypeInfo
    dtypes::Vector{JldDatatype}
    offsets::Vector{Int}
    size::Int
end

# Get information about the HDF5 types corresponding to Julia types
function JldTypeInfo(parent::JldFile, types::(@compat Tuple{Vararg{Type}}), commit::Bool)
    dtypes = Array(JldDatatype, length(types))
    offsets = Array(Int, length(types))
    offset = 0
    for i = 1:length(types)
        dtype = dtypes[i] = h5fieldtype(parent, types[i], commit)
        offsets[i] = offset
        offset += HDF5.h5t_get_size(dtype)
    end
    JldTypeInfo(dtypes, offsets, offset)
end
JldTypeInfo(parent::JldFile, T::ANY, commit::Bool) =
    JldTypeInfo(parent, T.types, commit)

# Write an HDF5 datatype to the file
function commit_datatype(parent::JldFile, dtype::HDF5Datatype, T::ANY)
    pparent = parent.plain
    if !exists(pparent, pathtypes)
        gtypes = g_create(pparent, pathtypes)
    else
        gtypes = pparent[pathtypes]
    end

    id = length(gtypes)+1
    try
        HDF5.t_commit(gtypes, @sprintf("%08d", id), dtype)
    finally
        close(gtypes)
    end
    a_write(dtype, name_type_attr, full_typename(parent, T))

    # Store in map
    parent.jlh5type[T] = JldDatatype(dtype, id)
end

# If parent is nothing, we are creating the datatype in memory for
# validation, so don't commit it
commit_datatype(parent::Nothing, dtype::HDF5Datatype, T::ANY) =
    JldDatatype(dtype, -1)

# The HDF5 library loses track of relationships among committed types
# after the file is saved. We mangle the names by appending a
# sequential identifier so that we can recover these relationships
# later.
mangle_name(jtype::JldDatatype, jlname) =
    jtype.index <= 0 ? string(jlname, "_") : string(jlname, "_", jtype.index)
Base.convert(::Type{HDF5.Hid}, x::JldDatatype) = x.dtype.id

## Serialization of datatypes to JLD
##
## h5fieldtype - gets the JldDatatype corresponding to a given
## Julia type, when the Julia type is stored as an element of an HDF5
## compound type or array. This is the only function that can operate
## on non-leaf types.
##
## h5type - gets the JldDatatype corresponding to an object of the
## given Julia type. For pointerfree types, this is usually the same as
## the h5fieldtype.
##
## h5convert! - converts data from Julia to HDF5 in a buffer. Most
## methods are dynamically generated by gen_h5convert, but methods for
## special built-in types are predefined.
##
## jlconvert - converts data from HDF5 to a Julia object.
##
## jlconvert! - converts data from HDF5 to Julia in a buffer. This is
## only applicable in cases where fields of that type may not be stored
## as references (e.g., not plain types).

## Special types
##
## To create a special serialization of a datatype, one should:
##
## - Define a method of h5fieldtype that dispatches to h5type
## - Define a method of h5type that constructs the type
## - Define a no-op method for gen_h5convert
## - Define h5convert! and jlconvert
## - If the type is an immutable, define jlconvert!
## - Add the type to BUILTIN_TYPES

## HDF5 bits kinds

# This construction prevents these methods from getting called on type unions
@eval typealias BitsKindTypes Union($(map(x->Type{x}, HDF5.HDF5BitsKind.types)...))

h5fieldtype(parent::JldFile, T::BitsKindTypes, ::Bool) =
    h5type(parent, T, false)

h5type(::JldFile, T::BitsKindTypes, ::Bool) =
    JldDatatype(HDF5Datatype(HDF5.hdf5_type_id(T), false), 0)

gen_h5convert(::JldFile, ::BitsKindTypes) = nothing
h5convert!{T<:HDF5.HDF5BitsKind}(out::Ptr, ::JldFile, x::T, ::JldWriteSession) =
    unsafe_store!(convert(Ptr{T}, out), x)

_jlconvert_bits{T}(::Type{T}, ptr::Ptr) = unsafe_load(convert(Ptr{T}, ptr))
_jlconvert_bits!{T}(out::Ptr, ::Type{T}, ptr::Ptr) =
    (unsafe_store!(convert(Ptr{T}, out), unsafe_load(convert(Ptr{T}, ptr))); nothing)

jlconvert(T::BitsKindTypes, ::JldFile, ptr::Ptr) = _jlconvert_bits(T, ptr)
jlconvert!(out::Ptr, T::BitsKindTypes, ::JldFile, ptr::Ptr) = _jlconvert_bits!(out, T, ptr)

## Void/Nothing

typealias VoidType Type{Nothing}

gen_jlconvert(typeinfo::JldTypeInfo, T::VoidType) = nothing

jlconvert(T::VoidType, ::JldFile, ptr::Ptr) = nothing
jlconvert!(out::Ptr, T::VoidType, ::JldFile, ptr::Ptr) = (unsafe_store!(convert(Ptr{T}, out), nothing); nothing)

## ByteStrings

h5fieldtype{T<:ByteString}(parent::JldFile, ::Type{T}, ::Bool) =
    h5type(parent, T, false)

# Stored as variable-length strings
function h5type{T<:ByteString}(::JldFile, ::Type{T}, ::Bool)
    type_id = HDF5.h5t_copy(HDF5.hdf5_type_id(T))
    HDF5.h5t_set_size(type_id, HDF5.H5T_VARIABLE)
    HDF5.h5t_set_cset(type_id, HDF5.cset(T))
    JldDatatype(HDF5Datatype(type_id, false), 0)
end

gen_h5convert{T<:ByteString}(::JldFile, ::Type{T}) = nothing
h5convert!(out::Ptr, ::JldFile, x::ByteString, ::JldWriteSession) =
    unsafe_store!(convert(Ptr{Ptr{UInt8}}, out), pointer(x))

function jlconvert(T::Union(Type{ASCIIString}, Type{UTF8String}), ::JldFile, ptr::Ptr)
    strptr = unsafe_load(convert(Ptr{Ptr{UInt8}}, ptr))
    n = @compat Int(ccall(:strlen, Csize_t, (Ptr{UInt8},), strptr))
    T(pointer_to_array(strptr, n, true))
end

function jlconvert(T::Union(Type{ByteString}), ::JldFile, ptr::Ptr)
    strptr = unsafe_load(convert(Ptr{Ptr{UInt8}}, ptr))
    str = bytestring(strptr)
    Libc.free(strptr)
    str
end

## UTF16Strings

h5fieldtype(parent::JldFile, ::Type{UTF16String}, commit::Bool) =
    h5type(parent, UTF16String, commit)

# Stored as compound types that contain a vlen
function h5type(parent::JldFile, ::Type{UTF16String}, commit::Bool)
    haskey(parent.jlh5type, UTF16String) && return parent.jlh5type[UTF16String]
    vlen = HDF5.h5t_vlen_create(HDF5.H5T_NATIVE_UINT16)
    id = HDF5.h5t_create(HDF5.H5T_COMPOUND, HDF5.h5t_get_size(vlen))
    HDF5.h5t_insert(id, "data_", 0, vlen)
    HDF5.h5t_close(vlen)
    dtype = HDF5Datatype(id, parent.plain)
    commit ? commit_datatype(parent, dtype, UTF16String) : JldDatatype(dtype, -1)
end

gen_h5convert(::JldFile, ::Type{UTF16String}) = nothing
h5convert!(out::Ptr, ::JldFile, x::UTF16String, ::JldWriteSession) =
    unsafe_store!(convert(Ptr{HDF5.Hvl_t}, out), HDF5.Hvl_t(length(x.data), pointer(x.data)))

function jlconvert(::Type{UTF16String}, ::JldFile, ptr::Ptr)
    hvl = unsafe_load(convert(Ptr{HDF5.Hvl_t}, ptr))
    UTF16String(pointer_to_array(convert(Ptr{UInt16}, hvl.p), hvl.len, true))
end

## Symbols

h5fieldtype(parent::JldFile, ::Type{Symbol}, commit::Bool) =
    h5type(parent, Symbol, commit)

# Stored as a compound type that contains a variable length string
function h5type(parent::JldFile, ::Type{Symbol}, commit::Bool)
    haskey(parent.jlh5type, Symbol) && return parent.jlh5type[Symbol]
    id = HDF5.h5t_create(HDF5.H5T_COMPOUND, 8)
    HDF5.h5t_insert(id, "symbol_", 0, h5fieldtype(parent, UTF8String, commit))
    dtype = HDF5Datatype(id, parent.plain)
    commit ? commit_datatype(parent, dtype, Symbol) : JldDatatype(dtype, -1)
end

gen_h5convert(::JldFile, ::Type{Symbol}) = nothing
function h5convert!(out::Ptr, file::JldFile, x::Symbol, wsession::JldWriteSession)
    str = string(x)
    push!(wsession.persist, str)
    h5convert!(out, file, str, wsession)
end

jlconvert(::Type{Symbol}, file::JldFile, ptr::Ptr) = symbol(jlconvert(UTF8String, file, ptr))


## BigInts and BigFloats

h5fieldtype(parent::JldFile, T::Union(Type{BigInt}, Type{BigFloat}), commit::Bool) =
    h5type(parent, T, commit)

# Stored as a compound type that contains a variable length string
function h5type(parent::JldFile, T::Union(Type{BigInt}, Type{BigFloat}), commit::Bool)
    haskey(parent.jlh5type, T) && return parent.jlh5type[T]
    id = HDF5.h5t_create(HDF5.H5T_COMPOUND, 8)
    HDF5.h5t_insert(id, "data_", 0, h5fieldtype(parent, ASCIIString, commit))
    dtype = HDF5Datatype(id, parent.plain)
    commit ? commit_datatype(parent, dtype, T) : JldDatatype(dtype, -1)
end

gen_h5convert(::JldFile, ::Union(Type{BigInt}, Type{BigFloat})) = nothing
function h5convert!(out::Ptr, file::JldFile, x::BigInt, wsession::JldWriteSession)
    str = base(62, x)
    push!(wsession.persist, str)
    h5convert!(out, file, str, wsession)
end
function h5convert!(out::Ptr, file::JldFile, x::BigFloat, wsession::JldWriteSession)
    str = string(x)
    push!(wsession.persist, str)
    h5convert!(out, file, str, wsession)
end

if VERSION < v"0.4.0-dev+3864"
    jlconvert(::Type{BigInt}, file::JldFile, ptr::Ptr) =
        Base.parseint_nocheck(BigInt, jlconvert(ASCIIString, file, ptr), 62)
else
    jlconvert(::Type{BigInt}, file::JldFile, ptr::Ptr) =
        get(tryparse(BigInt, jlconvert(ASCIIString, file, ptr), 62))
end
jlconvert(::Type{BigFloat}, file::JldFile, ptr::Ptr) =
    BigFloat(jlconvert(ASCIIString, file, ptr))

## Types

h5fieldtype{T<:Type}(parent::JldFile, ::Type{T}, commit::Bool) =
    h5type(parent, Type, commit)

# Stored as a compound type that contains a variable length string
function h5type{T<:Type}(parent::JldFile, ::Type{T}, commit::Bool)
    haskey(parent.jlh5type, Type) && return parent.jlh5type[Type]
    id = HDF5.h5t_create(HDF5.H5T_COMPOUND, 8)
    HDF5.h5t_insert(id, "typename_", 0, h5fieldtype(parent, UTF8String, commit))
    dtype = HDF5Datatype(id, parent.plain)
    commit ? commit_datatype(parent, dtype, Type) : JldDatatype(dtype, -1)
end

gen_h5convert{T<:Type}(::JldFile, ::Type{T}) = nothing

function h5convert!(out::Ptr, file::JldFile, x::Type, wsession::JldWriteSession)
    str = full_typename(file, x)
    push!(wsession.persist, str)
    h5convert!(out, file, str, wsession)
end

jlconvert{T<:Type}(::Type{T}, file::JldFile, ptr::Ptr) = julia_type(jlconvert(UTF8String, file, ptr))

## Pointers

h5type{T<:Ptr}(parent::JldFile, ::Type{T}, ::Bool) = throw(PointerException())

## Union()

h5fieldtype(parent::JldFile, ::Type{Union()}, ::Bool) = JLD_REF_TYPE

## Arrays

# These show up as having T.size == 0, hence the need for
# specialization.
h5fieldtype{T,N}(parent::JldFile, ::Type{Array{T,N}}, ::Bool) = JLD_REF_TYPE

## User-defined types
##
## Similar to special types, but h5convert!/jl_convert are dynamically
## generated.

## Tuples

if INLINE_TUPLE
    h5fieldtype(parent::JldFile, T::(@compat Tuple{Vararg{Type}}), commit::Bool) =
        isleaftype(T) ? h5type(parent, T, commit) : JLD_REF_TYPE
else
    h5fieldtype(parent::JldFile, T::(@compat Tuple{Vararg{Type}}), ::Bool) = JLD_REF_TYPE
end

function h5type(parent::JldFile, T::(@compat Tuple{Vararg{Type}}), commit::Bool)
    !isa(T, (@compat Tuple{Vararg{Union((@compat Tuple), DataType)}})) && unknown_type_err(T)
    T = T::(@compat Tuple{Vararg{Union((@compat Tuple), DataType)}})

    haskey(parent.jlh5type, T) && return parent.jlh5type[T]
    # Tuples should always be concretely typed, unless we're
    # reconstructing a tuple, in which case commit will be false
    !commit || isleaftype(T) || error("unexpected non-leaf type $T")

    typeinfo = JldTypeInfo(parent, T, commit)
    if isopaque(T)
        id = HDF5.h5t_create(HDF5.H5T_OPAQUE, opaquesize(T))
    else
        id = HDF5.h5t_create(HDF5.H5T_COMPOUND, typeinfo.size)
    end
    for i = 1:length(typeinfo.offsets)
        fielddtype = typeinfo.dtypes[i]
        HDF5.h5t_insert(id, mangle_name(fielddtype, i), typeinfo.offsets[i], fielddtype)
    end

    dtype = HDF5Datatype(id, parent.plain)
    if commit
        jlddtype = commit_datatype(parent, dtype, T)
        if isempty(T)
            # to allow recovery of empty tuples, which HDF5 does not allow
            a_write(dtype, "empty", @compat UInt8(1))
        end
        jlddtype
    else
        JldDatatype(dtype, -1)
    end
end

function gen_jlconvert(typeinfo::JldTypeInfo, T::(@compat Tuple{Vararg{Type}}))
    haskey(JLCONVERT_DEFINED, T) && return

    ex = Expr(:block)
    args = ex.args
    tup = Expr(:tuple)
    tupargs = tup.args
    for i = 1:length(typeinfo.dtypes)
        h5offset = typeinfo.offsets[i]
        field = symbol(string("field", i))

        if HDF5.h5t_get_class(typeinfo.dtypes[i]) == HDF5.H5T_REFERENCE
            push!(args, :($field = read_ref(file, unsafe_load(convert(Ptr{HDF5ReferenceObj}, ptr)+$h5offset))))
        else
            push!(args, :($field = jlconvert($(T[i]), file, ptr+$h5offset)))
        end
        push!(tupargs, field)
    end
    @eval jlconvert(::Type{$T}, file::JldFile, ptr::Ptr) = ($ex; $tup)
    JLCONVERT_DEFINED[T] = true
    nothing
end

## All other objects

# For cases not defined above: If the type is mutable and non-empty,
# this is a reference. If the type is immutable, this is a type itself.
if INLINE_POINTER_IMMUTABLE
    h5fieldtype(parent::JldFile, T::ANY, commit::Bool) =
        isleaftype(T) && (!T.mutable || T.size == 0) ? h5type(parent, T, commit) : JLD_REF_TYPE
else
    h5fieldtype(parent::JldFile, T::ANY, commit::Bool) =
        isleaftype(T) && (!T.mutable || T.size == 0) && T.pointerfree ? h5type(parent, T, commit) : JLD_REF_TYPE
end

function h5type(parent::JldFile, T::ANY, commit::Bool)
    !isa(T, DataType) && unknown_type_err(T)
    T = T::DataType

    haskey(parent.jlh5type, T) && return parent.jlh5type[T]
    isleaftype(T) || error("unexpected non-leaf type ", T)

    if isopaque(T)
        # Empty type or non-basic bitstype
        id = HDF5.h5t_create(HDF5.H5T_OPAQUE, opaquesize(T))
    else
        # Compound type
        typeinfo = JldTypeInfo(parent, T.types, commit)
        id = HDF5.h5t_create(HDF5.H5T_COMPOUND, typeinfo.size)
        for i = 1:length(typeinfo.offsets)
            fielddtype = typeinfo.dtypes[i]
            HDF5.h5t_insert(id, mangle_name(fielddtype, HDF5.getnames(T)[i]), typeinfo.offsets[i], fielddtype)
        end
    end

    dtype = HDF5Datatype(id, parent.plain)
    if commit
        jlddtype = commit_datatype(parent, dtype, T)
        if T.size == 0
            # to allow recovery of empty types, which HDF5 does not allow
            a_write(dtype, "empty", @compat UInt8(1))
        end
        jlddtype
    else
        JldDatatype(dtype, -1)
    end
end

# Normal objects
function _gen_jlconvert_type(typeinfo::JldTypeInfo, T::ANY)
    ex = Expr(:block)
    args = ex.args
    for i = 1:length(typeinfo.dtypes)
        h5offset = typeinfo.offsets[i]

        if HDF5.h5t_get_class(typeinfo.dtypes[i]) == HDF5.H5T_REFERENCE
            push!(args, quote
                ref = unsafe_load(convert(Ptr{HDF5ReferenceObj}, ptr)+$h5offset)
                if ref != HDF5.HDF5ReferenceObj_NULL
                    out.$(HDF5.getnames(T)[i]) = convert($(T.types[i]), read_ref(file, ref))
                end
            end)
        else
            push!(args, :(out.$(HDF5.getnames(T)[i]) = jlconvert($(T.types[i]), file, ptr+$h5offset)))
        end
    end
    @eval function jlconvert(::Type{$T}, file::JldFile, ptr::Ptr)
        out = ccall(:jl_new_struct_uninit, Any, (Any,), $T)::$T
        $ex
        out
    end
    nothing
end

# Immutables
function _gen_jlconvert_immutable(typeinfo::JldTypeInfo, T::ANY)
    ex = Expr(:block)
    args = ex.args
    jloffsets = fieldoffsets(T)
    for i = 1:length(typeinfo.dtypes)
        h5offset = typeinfo.offsets[i]
        jloffset = jloffsets[i]

        if HDF5.h5t_get_class(typeinfo.dtypes[i]) == HDF5.H5T_REFERENCE
            obj = gensym("obj")
            push!(args, quote
                ref = unsafe_load(convert(Ptr{HDF5ReferenceObj}, ptr)+$h5offset)
                local $obj # must keep alive to prevent collection
                if ref == HDF5.HDF5ReferenceObj_NULL
                    unsafe_store!(convert(Ptr{Int}, out)+$jloffset, 0)
                else
                    # The typeassert ensures that the reference type is
                    # valid for this type
                    $obj = read_ref(file, ref)::$(T.types[i])
                    unsafe_store!(convert(Ptr{Ptr{Void}}, out)+$jloffset, pointer_from_objref($obj))
                end
            end)
        elseif uses_reference(T.types[i])
            # Tuple fields and non-pointerfree immutables are stored
            # inline by JLD if INLINE_TUPLE/INLINE_POINTER_IMMUTABLE is
            # true, but not by Julia
            obj = gensym("obj")
            push!(args, quote
                $obj = jlconvert($(T.types[i]), file, ptr+$h5offset)
                unsafe_store!(convert(Ptr{Ptr{Void}}, out)+$jloffset, pointer_from_objref($obj))
            end)
        else
            push!(args, :(jlconvert!(out+$jloffset, $(T.types[i]), file, ptr+$h5offset)))
        end
    end
    @eval begin
        jlconvert!(out::Ptr, ::Type{$T}, file::JldFile, ptr::Ptr) = ($ex; nothing)
        $(
        if T.pointerfree
            quote
                function jlconvert(::Type{$T}, file::JldFile, ptr::Ptr)
                    out = Array($T, 1)
                    jlconvert!(pointer(out), $T, file, ptr)
                    out[1]
                end
            end
        else
            # XXX can this be improved?
            quote
                function jlconvert(::Type{$T}, file::JldFile, ptr::Ptr)
                    out = ccall(:jl_new_struct_uninit, Any, (Any,), $T)::$T
                    jlconvert!(pointer_from_objref(out)+$(VERSION >= v"0.4.0-dev+3923" ? 0 : sizeof(Int)), $T, file, ptr)
                    out
                end
            end
        end
        )
    end
    nothing
end

const DONT_STORE_SINGLETON_IMMUTABLES = VERSION >= v"0.4.0-dev+385"
function gen_jlconvert(typeinfo::JldTypeInfo, T::ANY)
    haskey(JLCONVERT_DEFINED, T) && return

    if isempty(HDF5.getnames(T))
        if T.size == 0
            @eval begin
                jlconvert(::Type{$T}, ::JldFile, ::Ptr) = $T()
                jlconvert!(out::Ptr, ::Type{$T}, ::JldFile, ::Ptr) =
                    $(DONT_STORE_SINGLETON_IMMUTABLES && !T.mutable ? nothing :
                      :(unsafe_store!(convert(Ptr{Ptr{Void}}, out), pointer_from_objref($T()))))
            end
        else
            @eval begin
               jlconvert(::Type{$T}, ::JldFile, ptr::Ptr) =  _jlconvert_bits($T, ptr)
               jlconvert!(out::Ptr, ::Type{$T}, ::JldFile, ptr::Ptr) =  _jlconvert_bits!(out, $T, ptr)
            end
        end
        nothing
    elseif T.size == 0
        @eval begin
            jlconvert(::Type{$T}, ::JldFile, ::Ptr) = ccall(:jl_new_struct_uninit, Any, (Any,), $T)::$T
            jlconvert!(out::Ptr, ::Type{$T}, ::JldFile, ::Ptr) = nothing
        end
    elseif T.mutable
        _gen_jlconvert_type(typeinfo, T)
    else
        _gen_jlconvert_immutable(typeinfo, T)
    end
    JLCONVERT_DEFINED[T] = true
    nothing
end

## Common functions for all non-special types (including gen_h5convert)

# Whether this datatype should be stored as opaque
isopaque(t::@compat Tuple{Vararg{Type}}) = isa(t, ())
isopaque(t::DataType) = isempty(HDF5.getnames(t))

# The size of this datatype in the HDF5 file (if opaque)
opaquesize(t::@compat Tuple{Vararg{DataType}}) = 1
opaquesize(t::DataType) = max(1, t.size)

# Whether a type that is stored inline in HDF5 should be stored as a
# reference in Julia. This will only be called such that it returns
# true for some unions of special types defined above, unless either
# INLINE_TUPLE or INLINE_POINTER_IMMUTABLE is true.
uses_reference(T::DataType) = !T.pointerfree
uses_reference(::@compat Tuple) = true
uses_reference(::UnionType) = true

unknown_type_err(T) =
    error("""$T is not of a type supported by JLD
             Please report this error at https://github.com/timholy/HDF5.jl""")

gen_h5convert(parent::JldFile, T) =
    haskey(H5CONVERT_DEFINED, T) || _gen_h5convert(parent, T)

# There is no point in specializing this
function _gen_h5convert(parent::JldFile, T::ANY)
    dtype = parent.jlh5type[T].dtype
    istuple = isa(T, @compat Tuple)
    if istuple
        types = T
    else
        if isopaque(T::DataType)
            if (T::DataType).size == 0
                @eval h5convert!(out::Ptr, ::JldFile, x::$T, ::JldWriteSession) = nothing
            else
                @eval h5convert!(out::Ptr, ::JldFile, x::$T, ::JldWriteSession) =
                    unsafe_store!(convert(Ptr{$T}, out), x)
            end
            return
        end
        types = (T::DataType).types
    end

    getindex_fn = istuple ? (:getindex) : (:getfield)
    ex = Expr(:block)
    args = ex.args
    n = HDF5.h5t_get_nmembers(dtype.id)
    for i = 1:n
        offset = HDF5.h5t_get_member_offset(dtype.id, i-1)
        if HDF5.h5t_get_member_class(dtype.id, i-1) == HDF5.H5T_REFERENCE
            if istuple
                push!(args, :(unsafe_store!(convert(Ptr{HDF5ReferenceObj}, out)+$offset,
                                            write_ref(file, $getindex_fn(x, $i), wsession))))
            else
                push!(args, quote
                    if isdefined(x, $i)
                        ref = write_ref(file, $getindex_fn(x, $i), wsession)
                    else
                        ref = HDF5.HDF5ReferenceObj_NULL
                    end
                    unsafe_store!(convert(Ptr{HDF5ReferenceObj}, out)+$offset, ref)
                end)
            end
        else
            gen_h5convert(parent, types[i])
            push!(args, :(h5convert!(out+$offset, file, $getindex_fn(x, $i), wsession)))
        end
    end
    @eval h5convert!(out::Ptr, file::JldFile, x::$T, wsession::JldWriteSession) = ($ex; nothing)
    H5CONVERT_DEFINED[T] = true
    nothing
end

## Find the corresponding Julia type for a given HDF5 type

# Type mapping function. Given an HDF5Datatype, find (or construct) the
# corresponding Julia type.
function jldatatype(parent::JldFile, dtype::HDF5Datatype)
    class_id = HDF5.h5t_get_class(dtype.id)
    if class_id == HDF5.H5T_STRING
        cset = HDF5.h5t_get_cset(dtype.id)
        if cset == HDF5.H5T_CSET_ASCII
            return ASCIIString
        elseif cset == HDF5.H5T_CSET_UTF8
            return UTF8String
        else
            error("character set ", cset, " not recognized")
        end
    elseif class_id == HDF5.H5T_INTEGER || class_id == HDF5.H5T_FLOAT
        # This can be a performance hotspot
        HDF5.h5t_equal(dtype.id, HDF5.H5T_NATIVE_DOUBLE) > 0 && return Float64
        HDF5.h5t_equal(dtype.id, HDF5.H5T_NATIVE_INT64) > 0 && return Int64
        HDF5.h5t_equal(dtype.id, HDF5.H5T_NATIVE_FLOAT) > 0 && return Float32
        HDF5.h5t_equal(dtype.id, HDF5.H5T_NATIVE_INT32) > 0 && return Int32
        HDF5.h5t_equal(dtype.id, HDF5.H5T_NATIVE_UINT8) > 0 && return UInt8
        HDF5.h5t_equal(dtype.id, HDF5.H5T_NATIVE_UINT64) > 0 && return UInt64
        HDF5.h5t_equal(dtype.id, HDF5.H5T_NATIVE_UINT32) > 0 && return UInt32
        HDF5.h5t_equal(dtype.id, HDF5.H5T_NATIVE_INT8) > 0 && return Int8
        HDF5.h5t_equal(dtype.id, HDF5.H5T_NATIVE_INT16) > 0 && return Int16
        HDF5.h5t_equal(dtype.id, HDF5.H5T_NATIVE_UINT16) > 0 && return UInt16
        error("unrecognized integer or float type")
    elseif class_id == HDF5.H5T_COMPOUND || class_id == HDF5.H5T_OPAQUE
        addr = HDF5.objinfo(dtype).addr
        haskey(parent.h5jltype, addr) && return parent.h5jltype[addr]

        typename = a_read(dtype, name_type_attr)
        T = julia_type(typename)
        if T == UnsupportedType
            warn("type $typename not present in workspace; reconstructing")
            T = reconstruct_type(parent, dtype, typename)
        end

        if !(T in BUILTIN_TYPES)
            # Call jldatatype on dependent types to validate them and
            # define jlconvert
            if class_id == HDF5.H5T_COMPOUND
                for i = 0:HDF5.h5t_get_nmembers(dtype.id)-1
                    member_name = HDF5.h5t_get_member_name(dtype.id, i)
                    idx = rsearchindex(member_name, "_")
                    if idx != sizeof(member_name)
                        member_dtype = HDF5.t_open(parent.plain, string(pathtypes, '/', lpad(member_name[idx+1:end], 8, '0')))
                        jldatatype(parent, member_dtype)
                    end
                end
            end

            gen_jlconvert(JldTypeInfo(parent, T, false), T)
        end

        # Verify that types match
        newtype = h5type(parent, T, false).dtype
        dtype == newtype || throw(TypeMismatchException(typename))

        # Store type in type index
        index = typeindex(parent, addr)
        parent.jlh5type[T] = JldDatatype(dtype, index)
        parent.h5jltype[addr] = T
        T
    else
        error("unrecognized HDF5 datatype class ", class_id)
    end
end

# Create a Julia type based on the HDF5Datatype from the file. Used
# when the type is no longer available.
function reconstruct_type(parent::JldFile, dtype::HDF5Datatype, savedname::AbstractString)
    name = gensym(savedname)
    class_id = HDF5.h5t_get_class(dtype.id)
    if class_id == HDF5.H5T_OPAQUE
        if exists(dtype, "empty")
            @eval (immutable $name; end; $name)
        else
            sz = @compat Int(HDF5.h5t_get_size(dtype.id))*8
            @eval (bitstype $sz $name; $name)
        end
    else
        # Figure out field names and types
        nfields = HDF5.h5t_get_nmembers(dtype.id)
        fieldnames = Array(Symbol, nfields)
        fieldtypes = Array(Type, nfields)
        for i = 1:nfields
            membername = HDF5.h5t_get_member_name(dtype.id, i-1)
            idx = rsearchindex(membername, "_")
            fieldname = fieldnames[i] = symbol(membername[1:idx-1])

            if idx != sizeof(membername)
                # There is something past the underscore in the HDF5 field
                # name, so the type is stored in file
                memberdtype = HDF5.t_open(parent.plain, string(pathtypes, '/', lpad(membername[idx+1:end], 8, '0')))
                fieldtypes[i] = jldatatype(parent, memberdtype)
            else
                memberclass = HDF5.h5t_get_member_class(dtype.id, i-1)
                if memberclass == HDF5.H5T_REFERENCE
                    # Field is a reference, so use Any
                    fieldtypes[i] = Any
                else
                    # Type is built-in
                    memberdtype = HDF5Datatype(HDF5.h5t_get_member_type(dtype.id, i-1), parent.plain)
                    fieldtypes[i] = jldatatype(parent, memberdtype)
                end
            end
        end

        if startswith(savedname, "(")
            # We're reconstructing a tuple
            tuple(fieldtypes...)
        else
            # We're reconstructing some other type
            @eval begin
                immutable $name
                    $([:($(fieldnames[i])::$(fieldtypes[i])) for i = 1:nfields]...)
                end
                $name
            end
        end
    end
end

# Get the index of a type in the types group. This could be cached, but
# it's already many times faster than calling H5Iget_name with a lot of
# data in the file, and it only needs to be called once per type.
# Revisit if this ever turns out to be a bottleneck.
function typeindex(parent::JldFile, addr::HDF5.Haddr)
    gtypes = parent.plain[pathtypes]
    i = 1
    for x in gtypes
        if HDF5.objinfo(x).addr == addr
            return i
        end
        i += 1
    end
end
