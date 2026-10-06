# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

import Test

Test.@testset "Package Juleana" begin
    include("test_aqua.jl")
    include("test_juleana.jl")
    include("test_filter_optimization_utils.jl")
    include("test_docs.jl")
end # testset
