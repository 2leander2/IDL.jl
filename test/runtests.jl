using IDL
using Test
using Random

function check_roundtrip(val_in, name_suffix)
    var_name = "test_$(name_suffix)"
    try
        IDL.put_var(val_in, var_name)
        val_out = IDL.get_var(var_name)
        
        # 1. Type Verification
        if typeof(val_out) != typeof(val_in)
            # IDL often returns scalar 1-element arrays as vectors. This is acceptable.
            # We strictly fail only if the element types mismatch (e.g. Float32 vs Float64)
            if eltype(val_out) != eltype(val_in)
                @error "TYPE MISMATCH: $var_name" Expected=typeof(val_in) Got=typeof(val_out)
                return false
            end
        end
        
        # 2. Value Verification (isequal handles NaN==NaN correctly)
        if !isequal(val_in, val_out)
            @error "VALUE MISMATCH: $var_name" Sent=val_in Got=val_out
            return false
        end
        
        return true
    catch e
        @error "CRASH on $var_name" exception=e
        return false
    end
end

@testset "IDL.jl Full Suite" begin

    @testset "Interface & Commands" begin
        println(">> Verifying Interface...")
        
        # Execution
        @test IDL.execute("print, 'IDL Link Active'") == nothing
        
        # Variable Mutation
        IDL.execute("a = 10")
        IDL.execute("a += 5")
        @test IDL.get_var("a") == 15

        # Block Execution
        block = """
        x = 100
        y = 200
        """
        IDL.execute(block)
        @test IDL.get_var("x") == 100
        @test IDL.get_var("y") == 200
    end

    numeric_types = [
        UInt8, Int16, UInt16, Int32, UInt32, Int64, UInt64, 
        Float32, Float64, ComplexF32, ComplexF64
    ]

    @testset "Numeric Fidelity" begin
        for T in numeric_types
            @testset "Type: $T" begin
                println(">> Testing Data Type: $T")
                
                # A. Scalar
                val_scalar = rand(T)
                @test check_roundtrip(val_scalar, "scal_$(T)")

                # B. 1D Vector
                val_vec = rand(T, 10)
                @test check_roundtrip(val_vec, "vec_$(T)")

                # C. 2D Matrix (Check Row/Col Major)
                val_mat = rand(T, 5, 5)
                @test check_roundtrip(val_mat, "mat_$(T)")

                # D. 3D Cube (Volumetric)
                val_cube = rand(T, 3, 3, 3)
                @test check_roundtrip(val_cube, "cube_$(T)")
            end
        end
    end

    @testset "String Handling" begin
        println(">> Testing Strings...")
        
        # Simple String
        @test check_roundtrip("Hello IDL", "str_simple")
        
        # String Array (Vector)
        str_vec = ["Alpha", "Beta", "Gamma"]
        @test check_roundtrip(str_vec, "str_vec")
        
        # String Matrix
        str_mat = ["A1" "B1"; "A2" "B2"]
        @test check_roundtrip(str_mat, "str_mat")
    end

    @testset "Robustness & Edge Cases" begin
        println(">> Testing Edge Cases...")

        # A. Special Floating Point Values
        floats = [NaN, Inf, -Inf, -0.0, 0.0]
        @test check_roundtrip(floats, "edge_floats")
        
        # B. Complex Edge Cases
        c_floats = [NaN + 1.0im, 1.0 + Inf*im]
        @test check_roundtrip(c_floats, "edge_complex")

        # C. Syntax Safety (Quotes in Strings)
        # This tests against SQL-injection-style syntax errors
        nasty_string = "Height: 5'10\""
        @test check_roundtrip(nasty_string, "syntax_quote")
        
        # D. Empty String
        @test check_roundtrip("", "empty_str")

        # E. Integer Limits (Overflow Check)
        @test check_roundtrip(typemax(Int64), "max_i64")
        @test check_roundtrip(typemin(Int64), "min_i64")
    end

end

IDL.reset()
