using Revise
import AMGCLWrap
using JutulDarcy

#simulate_mrst_case("C:/Users/Shaow/OneDrive/MIT/blackoil_co2/G_gom_predict.mat")
#simulate_mrst_case(raw"C:/Users/Shaow/OneDrive/MIT/mrst-2025a/SINTEF-AppliedCompSci-MRST-75749fa/core/output/jutul/qfs_wo.mat", write_mrst = true);
#simulate_mrst_case(raw"C:/Users/Shaow/OneDrive/MIT/mrst-2025a/SINTEF-AppliedCompSci-MRST-75749fa/core/output/jutul/PUNQ.mat", write_mrst = true)

simulate_mrst_case(raw"C:/Users/Shaow/OneDrive/MIT/mrst-2025a/SINTEF-AppliedCompSci-MRST-75749fa/core/output/jutul/diffusion.mat",write_mrst = true)

#simulate_mrst_case(raw"C:/Users/Shaow/OneDrive/MIT/mrst-2025a/SINTEF-AppliedCompSci-MRST-75749fa/core/output/jutul/SPE9THCOMPARATIVESTUDY_GenericBlackOilModel.mat", write_mrst = true)

# fn = raw"C:/Users/Shaow/OneDrive/MIT/mrst-2025a/SINTEF-AppliedCompSci-MRST-75749fa/core/output/jutul/diffusion.mat"

# case = setup_case_from_mrst(fn)[1]

# @show typeof(case)