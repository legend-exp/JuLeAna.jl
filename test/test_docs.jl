# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

using Test
using JuLeAna
import Documenter

Documenter.DocMeta.setdocmeta!(JuLeAna, :DocTestSetup, :(using JuLeAna); recursive = true)
Documenter.doctest(JuLeAna)
