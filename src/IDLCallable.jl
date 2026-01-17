include("idl_types.jl")
include("common-funcs.jl")
include("common-macros.jl")

using Libdl

if Sys.isapple()
    cd(idl_lib_dir) do
        Libdl.dlopen("libidl")
    end
end

function get_output(flags::Cint, buf::Ptr{UInt8}, n::Cint)
    line = unsafe_string(buf, n)
    stderr = (flags & IDL_TOUT_F_STDERR) != 0
    newline = (flags & IDL_TOUT_F_NLPOST) != 0
    if newline line = line*"\n" end
    print(line)
    return
end

function callable_init()
    ecode = ccall((:IDL_Initialize, idlcall), Cint,
        (Cint, Ptr{Cint}, Ptr{Ptr{UInt8}}), 0, C_NULL, C_NULL)
    ecode == 0 && error("IDL.init: IDL init failed")
    global output_cb = @cfunction(get_output, Nothing, (Cint, Ptr{UInt8}, Cint))
    ccall((:IDL_ToutPush, idlcall), Nothing, (Ptr{Nothing},), output_cb)
    ccall((:IDL_ExecuteStr, idlcall), Cint, (Ptr{UInt8},), "!EXCEPT=0")
end

# function execute{T<:AbstractString}(strarr::Array{T,1})
#     println("Strarray")
#     strarr =  ASCIIString[string(s) for s in strarr]
#     ecode = ccall((:IDL_Execute, idlcall), Cint, (Cint, Ptr{Ptr{UInt8}},), length(strarr), strarr)
#     if ecode != 0
#         # since error get printed by IDL, we just reset error state
#         ecode = ccall((:IDL_ExecuteStr, idlcall), Cint, (Ptr{UInt8},), "message, /RESET")
#     end
#     return nothing
# end

function execute_converted(str::AbstractString)
    # does no conversion of interpolated vars, continuation chars, or newlines
    ecode = ccall((:IDL_ExecuteStr, idlcall), Cint, (Ptr{UInt8},), str)
    if ecode != 0
        # since error get printed by IDL, we just reset error state
        ecode = ccall((:IDL_ExecuteStr, idlcall), Cint, (Ptr{UInt8},), "message, /RESET")
    end
    return true
end

# function exit()
#     # probably better to do a .full_reset instead
#     ecode = ccall((:IDL_Cleanup, idlcall), Cint, (Cint,), IDL_TRUE)
#     return nothing
# end

# hold a ref to imported variable so they don't get gc'ed
const var_refs = Dict{Ptr{UInt8}, Any}()

function done_with_var(p::Ptr{UInt8})
    if !haskey(var_refs, p)
        error("IDL.done_with_var: ptr not found: "*string(p))
    end
    delete!(var_refs, p)
    return
end

free_cb = @cfunction(done_with_var, Nothing, (Ptr{UInt8},))

function put_var(arr::Array{T,N}, name::AbstractString) where {T,N}
    code = idl_type(T)
    
    if !isbitstype(T) || (code < 0)
        error("IDL.put_var: Type $T not supported")
    end
    
    dim = zeros(Int, IDL_MAX_ARRAY_DIM)
    dim[1:N] = [size(arr)...]
    
    vptr = ccall((:IDL_ImportNamedArray, idlcall), Ptr{IDL_Variable},
    (Ptr{UInt8}, Cint, IDL_ARRAY_DIM, Cint, Ptr{UInt8}, IDL_ARRAY_FREE_CB , Ptr{Nothing}),
    name, N, dim, code, pointer(arr), free_cb, C_NULL)
    
    if vptr == C_NULL
        error("IDL.put_var: failed")
    end

    ptr_key = reinterpret(Ptr{UInt8}, pointer(arr))
    var_refs[ptr_key] = (name, vptr, arr)
    return
end

function put_var(x, name::AbstractString)
    if isa(x, AbstractString)
        # IDL escapes single quotes by doubling them (' -> '')
        safe_str = replace(x, "'" => "''")
        execute("$name = '$safe_str'")
        return

    elseif isa(x, Complex)
        re, im = real(x), imag(x)
        if isa(x, ComplexF64)
            execute("$name = dcomplex('$re', '$im')")
        else
            execute("$name = complex('$re', '$im')")
        end
        return

    elseif isa(x, AbstractFloat)
        if isa(x, Float64)
            execute("$name = double('$x')")
        else
            execute("$name = float('$x')")
        end
        return

    elseif isa(x, Integer)
        if isa(x, UInt8)
            execute("$name = byte($x)")
        elseif isa(x, Int16)
            execute("$name = fix($x)")
        elseif isa(x, UInt16)
            execute("$name = uint($x)")
        elseif isa(x, Int32)
            execute("$name = long($x)")
        elseif isa(x, UInt32)
            execute("$name = ulong($x)")
        elseif isa(x, Int64)
            execute("$name = long64($x)")
        elseif isa(x, UInt64)
            execute("$name = ulong64($x)")
        else
            execute("$name = $x")
        end
        return
    end

    # Fallback for weird types
    if !isbitstype(typeof(x)) || (idl_type(x) < 0)
        error("IDL.put_var: only works with some vars containing bits types")
    end
    
    dim = zeros(Int, IDL_MAX_ARRAY_DIM)
    dim[1] = 1
    arr = [x]
    ptr_key = reinterpret(Ptr{UInt8}, pointer(arr))

    ccall((:IDL_ImportNamedArray, idlcall), Ptr{Nothing},
    (Ptr{UInt8}, Cint, Ptr{IDL_MEMINT}, Cint, Ptr{UInt8}, Ptr{Nothing}, Ptr{Nothing}),
    name, 1, dim, idl_type(x), pointer(arr), C_NULL, C_NULL)
    
    execute("$name = $name[0]")
    return
end

function get_name(vptr::Ptr{IDL_Variable})
    str = ccall((:IDL_VarName, idlcall), Ptr{Cchar}, (Ptr{IDL_Variable},), vptr)
    return unsafe_string(str)
end

function get_vptr(name::AbstractString)
    # returns C_NULL if name not in scope
    name = uppercase(name)
    vptr = ccall((:IDL_GetVarAddr, idlcall), Ptr{IDL_Variable}, (Ptr{UInt8},), name)
    vptr
end

function get_var(name::AbstractString)
    name = uppercase(name)
    vptr = ccall((:IDL_GetVarAddr, idlcall), Ptr{IDL_Variable}, (Ptr{UInt8},), name)
    if vptr == C_NULL
        error("IDL.get_var: variable $name does not exist")
    end
    get_var(vptr)
end
