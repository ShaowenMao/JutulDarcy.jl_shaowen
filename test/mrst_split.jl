using JutulDarcy, Jutul, Test

function split_test_sgof(scale)
    return [
        0.0 0.0 1.0 0.0
        0.5 0.2 0.3 1.0e5*scale
        0.8 1.0 0.0 2.0e5*scale
    ]
end

function split_test_entry_sgof(scale)
    return [
        0.0 0.0 1.0 0.0
        1.0e-5 0.2 0.3 1.0e5*scale
        0.8 1.0 0.0 2.0e5*scale
    ]
end

function split_test_zero_pc_sgof()
    return [
        0.0 0.0 1.0 0.0
        0.2 0.2 0.3 0.0
        0.8 1.0 0.0 0.0
    ]
end

@testset "MRST reservoir-ready split input" begin
    for alias in (
            "plateau_all_active",
            "all_active_plateau",
            "domain_plateau",
            "plateau_all_active_drainage"
        )
        @test JutulDarcy.normalize_mrst_fault_pc_entry_treatment(alias) ==
            "plateau_all_active"
    end

    base_table = split_test_sgof(1.0)
    common = Dict{String, Any}(
        "rock" => Dict{String, Any}(
            "poro" => [0.2, 0.2, NaN, NaN],
            "perm" => reshape([1.0, 1.0, NaN, NaN], :, 1),
            "regions" => Dict{String, Any}(
                "saturation" => [1.0, 1.0, 2.0, 2.0],
                "imbibition" => [4.0, 4.0, 5.0, 5.0]
            )
        ),
        "deck" => Dict{String, Any}(
            "PROPS" => Dict{String, Any}(
                "SGOF" => reshape(Any[base_table, zeros(0, 0), zeros(0, 0)], :, 1)
            ),
            "RUNSPEC" => Dict{String, Any}(
                "TABDIMS" => [3.0]
            )
        )
    )

    custom_tables = Any[split_test_sgof(2.0), split_test_sgof(3.0)]
    specific = Dict{String, Any}(
        "schema" => "gom_jutul_split_specific_v2",
        "fault" => Dict{String, Any}(
            "cells" => [3.0, 4.0],
            "poro" => [0.15, 0.25],
            "perm" => reshape([2.0, 3.0], :, 1),
            "saturation_region" => [2.0, 3.0],
            "fluid_tables" => Dict{String, Any}(
                "SGOF" => Dict{String, Any}(
                    "regions" => [2.0, 3.0],
                    "tables" => reshape(custom_tables, :, 1)
                )
            )
        )
    )

    assembled = JutulDarcy.assemble_mrst_split_case(common, specific)
    regions = assembled["rock"]["regions"]
    sgof = vec(assembled["deck"]["PROPS"]["SGOF"])

    @test assembled["rock"]["poro"] == [0.2, 0.2, 0.15, 0.25]
    @test vec(assembled["rock"]["perm"]) == [1.0, 1.0, 2.0, 3.0]
    @test Int.(vec(regions["saturation"])) == [1, 1, 2, 3]
    @test !haskey(regions, "imbibition")
    @test length(sgof) == 3
    @test sgof[1] == base_table
    @test sgof[2] == custom_tables[1]
    @test sgof[3] == custom_tables[2]
    @test assembled["deck"]["RUNSPEC"]["NOHYST"] === true
    @test assembled["deck"]["RUNSPEC"]["TABDIMS"][1] == 3.0
    @test assembled["fault_saturation_domain_mode"] == "reservoir_ready_explicit"

    entry_tables = Any[split_test_entry_sgof(2.0), split_test_entry_sgof(3.0)]
    entry_specific = deepcopy(specific)
    entry_specific["fault"]["fluid_tables"]["SGOF"]["tables"] = reshape(entry_tables, :, 1)
    entry_assembled = JutulDarcy.assemble_mrst_split_case(
        common,
        entry_specific;
        fault_pc_entry_treatment = "plateau",
        fault_pc_entry_sg_max = 1.0e-4
    )
    entry_sgof = vec(entry_assembled["deck"]["PROPS"]["SGOF"])
    entry_summary = entry_assembled["fault_saturation_domain_summary"]["pc_entry_treatment"]

    @test entry_sgof[2][1, 4] == entry_sgof[2][2, 4]
    @test entry_sgof[3][1, 4] == entry_sgof[3][2, 4]
    @test entry_summary["treatment"] == "plateau"
    @test entry_summary["adjusted_tables"] == 2
    @test entry_summary["skipped_tables"] == 0

    base_imbibition_table = split_test_sgof(1.5)
    common_hysteresis = deepcopy(common)
    common_hysteresis["deck"]["PROPS"]["EHYSTR"] = Any[0, 3, 0, 0.0, "KR", 0, 0, "DEFAULT", 0, 0, 0, 0.05]
    common_hysteresis["deck"]["PROPS"]["SGOF"] = reshape(
        Any[base_table, zeros(0, 0), zeros(0, 0), base_imbibition_table, zeros(0, 0), zeros(0, 0)],
        :,
        1
    )
    common_hysteresis["deck"]["RUNSPEC"]["TABDIMS"] = [6.0]

    reservoir_hyst_assembled = JutulDarcy.assemble_mrst_split_case(
        common_hysteresis,
        entry_specific;
        fault_pc_entry_treatment = "plateau",
        fault_pc_entry_sg_max = 1.0e-4,
        explicit_fault_hysteresis_mode = "reservoir"
    )
    reservoir_hyst_regions = reservoir_hyst_assembled["rock"]["regions"]
    reservoir_hyst_sgof = vec(reservoir_hyst_assembled["deck"]["PROPS"]["SGOF"])
    reservoir_hyst_summary = reservoir_hyst_assembled["fault_saturation_domain_summary"]

    @test length(reservoir_hyst_sgof) == 6
    @test reservoir_hyst_sgof[1] == base_table
    @test reservoir_hyst_sgof[4] == base_imbibition_table
    @test reservoir_hyst_sgof[5] == reservoir_hyst_sgof[2]
    @test reservoir_hyst_sgof[6] == reservoir_hyst_sgof[3]
    @test reservoir_hyst_sgof[2][1, 4] == reservoir_hyst_sgof[2][2, 4]
    @test !haskey(reservoir_hyst_assembled["deck"]["RUNSPEC"], "NOHYST")
    @test Int.(vec(reservoir_hyst_regions["saturation"])) == [1, 1, 2, 3]
    @test Int.(vec(reservoir_hyst_regions["imbibition"])) == [4, 4, 5, 6]
    @test reservoir_hyst_assembled["deck"]["RUNSPEC"]["TABDIMS"][1] == 6.0
    @test reservoir_hyst_summary["hysteresis"] == "reservoir_only_fault_drainage_duplicate"
    @test reservoir_hyst_summary["pc_entry_treatment"]["adjusted_tables"] == 2

    domain_specific = deepcopy(entry_specific)
    domain_custom_tables =
        Any[split_test_entry_sgof(2.0), split_test_zero_pc_sgof()]
    domain_specific["fault"]["fluid_tables"]["SGOF"]["tables"] =
        reshape(domain_custom_tables, :, 1)
    domain_common_before = deepcopy(common_hysteresis)
    domain_specific_before = deepcopy(domain_specific)
    domain_assembled = JutulDarcy.assemble_mrst_split_case(
        common_hysteresis,
        domain_specific;
        fault_pc_entry_treatment = "plateau_all_active",
        explicit_fault_hysteresis_mode = "reservoir"
    )
    domain_sgof = vec(domain_assembled["deck"]["PROPS"]["SGOF"])
    domain_summary =
        domain_assembled["fault_saturation_domain_summary"]["pc_entry_treatment"]

    @test domain_sgof[1][1, 4] == domain_sgof[1][2, 4]
    @test domain_sgof[2][1, 4] == domain_sgof[2][2, 4]
    @test all(iszero, domain_sgof[3][:, 4])
    @test domain_sgof[1][2:end, 4] == base_table[2:end, 4]
    @test domain_sgof[2][2:end, 4] ==
        domain_custom_tables[1][2:end, 4]
    @test domain_sgof[3][:, 4] == domain_custom_tables[2][:, 4]
    @test domain_sgof[1][:, 1:3] == base_table[:, 1:3]
    @test domain_sgof[2][:, 1:3] == domain_custom_tables[1][:, 1:3]
    @test domain_sgof[3][:, 1:3] == domain_custom_tables[2][:, 1:3]
    @test domain_sgof[4] == base_imbibition_table
    @test domain_sgof[5] == domain_sgof[2]
    @test domain_sgof[6] == domain_sgof[3]
    @test domain_summary["treatment"] == "plateau_all_active"
    @test domain_summary["scope"] == "all_active_drainage"
    @test domain_summary["entry_rule"] ==
        "first_strictly_positive_pc_node"
    @test domain_summary["active_tables"] == 3
    @test domain_summary["nonzero_entry_tables"] == 2
    @test domain_summary["adjusted_tables"] == 2
    @test domain_summary["already_plateaued_tables"] == 0
    @test domain_summary["true_zero_pc_tables"] == 1
    @test domain_summary["skipped_tables"] == 1
    @test domain_summary["adjusted_regions"] == [1, 2]
    @test isempty(domain_summary["already_plateaued_regions"])
    @test domain_summary["true_zero_pc_regions"] == [3]
    @test domain_summary["mirrored_explicit_hysteresis_tables"] == 2
    @test domain_summary["base_imbibition_unchanged"] === true
    @test domain_summary["base_imbibition_sha256_before"] ==
        domain_summary["base_imbibition_sha256_after"]
    @test domain_summary["kr_unchanged"] === true
    @test domain_summary["pc_at_and_above_entry_unchanged"] === true
    @test domain_summary["kr_sha256_before"] ==
        domain_summary["kr_sha256_after"]
    @test domain_summary["pc_tail_sha256_before"] ==
        domain_summary["pc_tail_sha256_after"]
    @test domain_summary["input_drainage_sha256"] !=
        domain_summary["output_drainage_sha256"]
    for key in (
            "input_drainage_sha256",
            "output_drainage_sha256",
            "kr_sha256_before",
            "pc_tail_sha256_before"
        )
        digest = domain_summary[key]
        @test length(digest) == 64
        @test all(c -> isdigit(c) || c in 'a':'f', digest)
    end
    @test isequal(common_hysteresis, domain_common_before)
    @test isequal(domain_specific, domain_specific_before)

    # A whole-input control can use the same deterministic transformation as
    # split assembly. All post-plateau SGOF tables must then be identical.
    domain_whole = JutulDarcy.assemble_mrst_split_case(
        common_hysteresis,
        domain_specific;
        fault_pc_entry_treatment = "none",
        explicit_fault_hysteresis_mode = "reservoir"
    )
    get!(domain_whole, "metadata", Dict{String, Any}())[
        "shared_drainage_saturation_region_count"
    ] = 1
    whole_base_imbibition_before =
        copy(vec(domain_whole["deck"]["PROPS"]["SGOF"])[4])
    whole_summary =
        JutulDarcy.apply_mrst_whole_pc_entry_treatment!(
            domain_whole;
            fault_pc_entry_treatment = "plateau_all_active",
            explicit_fault_hysteresis_mode = "reservoir"
        )
    @test all(
        isequal.(vec(domain_whole["deck"]["PROPS"]["SGOF"]), domain_sgof)
    )
    @test vec(domain_whole["deck"]["PROPS"]["SGOF"])[4] ==
        whole_base_imbibition_before
    for key in (
            "input_drainage_sha256",
            "output_drainage_sha256",
            "kr_sha256_before",
            "kr_sha256_after",
            "pc_tail_sha256_before",
            "pc_tail_sha256_after",
            "base_imbibition_sha256_before",
            "base_imbibition_sha256_after"
        )
        @test whole_summary[key] == domain_summary[key]
    end
    @test whole_summary["mirrored_explicit_hysteresis_tables"] == 2
    @test whole_summary["drainage_region_count"] == 3
    @test domain_whole["fault_saturation_domain_summary"]["input_mode"] ==
        "whole"
    @test domain_whole["fault_saturation_domain_summary"][
        "pc_entry_treatment"
    ] === whole_summary
    @test_throws ErrorException begin
        JutulDarcy.apply_mrst_whole_pc_entry_treatment!(
            deepcopy(domain_whole);
            fault_pc_entry_treatment = "plateau"
        )
    end

    combined_common = deepcopy(common_hysteresis)
    combined_common["name"] = "tiny_common"
    combined_common["rock"]["poro"][2] = NaN
    combined_common["rock"]["perm"][2] = NaN
    combined_common["rock"]["regions"]["rocknum"] = [1.0, 1.0, 1.0, 1.0]
    combined_common["masks"] = Dict{String, Any}(
        "specificFaultCells" => [3.0, 4.0],
        "specificStratigraphyCells" => [2.0]
    )

    combined_specific = deepcopy(specific)
    combined_specific["schema"] = "gom_jutul_split_specific_v3"
    combined_specific["common_name"] = "tiny_common"
    combined_specific["geology_id"] = "s05_c012"
    combined_specific["geology_hash_algorithm"] = "SHA-256"
    combined_specific["geology_hash"] = repeat("a", 64)
    combined_specific["pairing_key"] = "s05_c012:" * repeat("a", 64)
    combined_specific["stratigraphy"] = Dict{String, Any}(
        "cells" => [2.0],
        "poro" => [0.31],
        "perm" => reshape([4.0], :, 1),
        "saturation_region" => [1.0],
        "rock_region" => [2.0],
        # Deliberately stale: explicit fault hysteresis processing must
        # replace this with SATNUM + final drainage-region count.
        "imbibition_region" => [99.0]
    )
    common_before = deepcopy(combined_common)
    specific_before = deepcopy(combined_specific)
    combined_assembled = JutulDarcy.assemble_mrst_split_case(
        combined_common,
        combined_specific;
        explicit_fault_hysteresis_mode = "reservoir",
        fault_pc_entry_treatment = "none"
    )
    combined_regions = combined_assembled["rock"]["regions"]

    @test combined_assembled["rock"]["poro"] == [0.2, 0.31, 0.15, 0.25]
    @test vec(combined_assembled["rock"]["perm"]) == [1.0, 4.0, 2.0, 3.0]
    @test Int.(vec(combined_regions["saturation"])) == [1, 1, 2, 3]
    @test Int.(vec(combined_regions["rocknum"])) == [1, 2, 1, 1]
    @test Int.(vec(combined_regions["imbibition"])) == [4, 4, 5, 6]
    @test combined_assembled["stratigraphy_specific_summary"]["cell_count"] == 1
    @test combined_assembled["qoi_stratigraphy"]["cells"] == Int32[2]
    @test combined_assembled["qoi_fault"]["cells"] == Int32[3, 4]
    @test isequal(combined_common, common_before)
    @test isequal(combined_specific, specific_before)

    overlapping = deepcopy(combined_specific)
    overlapping["stratigraphy"]["cells"] = [3.0]
    @test_throws ErrorException JutulDarcy.assemble_mrst_split_case(
        combined_common,
        overlapping;
        explicit_fault_hysteresis_mode = "reservoir"
    )
end

@testset "MRST hysteresis restart history" begin
    mktempdir() do output_path
        state = Dict{Symbol, Any}(
            :Reservoir => Dict{Symbol, Any}(:Pressure => [1.0])
        )
        Jutul.write_result_jld2(output_path, state, Dict{Symbol, Any}(), 1)
        @test_throws ErrorException JutulDarcy.validate_mrst_restart_history(
            output_path,
            2,
            [:MaxSaturations]
        )

        state[:Reservoir][:MaxSaturations] = [0.25]
        Jutul.write_result_jld2(output_path, state, Dict{Symbol, Any}(), 1)
        @test isnothing(JutulDarcy.validate_mrst_restart_history(
            output_path, 2, [:MaxSaturations]
        ))
    end
end
