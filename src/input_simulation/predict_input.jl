using Revise
using Pkg
#Pkg.activate(raw"D:\Github\JutulDarcy.jl_shaowen") #Desktop at home
Pkg.activate(raw"C:\\Users\\Shaow\\Documents\\GitHub\\JutulDarcy.jl_shaowen") # Dell laptop
using JutulDarcy

#simulate_mrst_case("C:/Users/Shaow/AppData/Local/Temp/qfs_wo", write_mrst = true, info_level=-1, ascii_terminal = true)
simulate_mrst_case("C:/predict_shaowen/JutulInputs/test3D.mat", write_mrst = true, info_level=-1, ascii_terminal = true)

