{ mkDerivation, base, base-compat, base16-bytestring, binary
, bytestring, constraints, containers, deepseq, fetchFromGitHub
, generic-data, hashable, lattices, lens, monad-st, mtl, pretty
, QuickCheck, hypertypes, transformers, stdenv
}:
mkDerivation {
  pname = "momentu";
  version = "0.1.0.0";
  src = fetchFromGitHub {
    owner = "lamdu";
    repo = "momentu";
    sha256 = "0hgm2wkclrv2hb749ibgn98npp7g8qwcji3k9rfnb412985igzi1";
    rev = "5f3f511ce51dc83d5d536832e8e45153dcf6e104";
  };
  libraryHaskellDepends = [
    aeson base base-compat binary bytestring containers deepseq generic-data GLFW-b
    graphics-drawingcombinators lens mtl OpenGL pretty safe-exceptions stm text time timeit
    unicode-properties base base-compat template-haskell
  ];
  homepage = "https://github.com/lamdu/momentu.git#readme";
  description = "The Momentu purely functional animated GUI framework";
  license = stdenv.lib.licenses.bsd3;
}
