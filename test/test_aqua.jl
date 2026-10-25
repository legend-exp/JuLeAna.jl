# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

import Test
import Aqua
import JuLeAna

Test.@testset "Package ambiguities" begin
    Test.@test isempty(Test.detect_ambiguities(JuLeAna))
end # testset

Test.@testset "Aqua tests" begin
    Aqua.test_all(JuLeAna, ambiguities = true, stale_deps = false)
end # testset
