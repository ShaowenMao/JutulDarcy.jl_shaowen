using JutulDarcy, Test

@testset "MRST liquid-vapor initial pressure reference" begin
    raw_pressure = [10.0, 20.0, 30.0]
    capillary_pressure = [1.0, 2.0, 3.0]

    liquid_reference = copy(raw_pressure)
    returned = JutulDarcy.convert_mrst_liquid_vapor_pressure_to_reference!(
        liquid_reference,
        capillary_pressure,
        1
    )
    @test returned === liquid_reference
    @test liquid_reference == raw_pressure

    vapor_reference = copy(raw_pressure)
    JutulDarcy.convert_mrst_liquid_vapor_pressure_to_reference!(
        vapor_reference,
        capillary_pressure,
        2
    )
    @test vapor_reference == raw_pressure .+ capillary_pressure

    @test_throws DimensionMismatch JutulDarcy.convert_mrst_liquid_vapor_pressure_to_reference!(
            copy(raw_pressure),
            capillary_pressure[1:2],
            1
        )
    @test_throws ArgumentError JutulDarcy.convert_mrst_liquid_vapor_pressure_to_reference!(
            copy(raw_pressure),
            capillary_pressure,
            3
        )
end
