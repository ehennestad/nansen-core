function root = repoRoot()
%repoRoot The nansen-core folder that holds schema/ and conformance/
    root = fileparts(fileparts(fileparts(fileparts(mfilename("fullpath")))));
end
