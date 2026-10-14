function folder = casesDirectory()
%casesDirectory The repository's conformance/ folder
    folder = string(fullfile(nansen.internal.repoRoot(), "conformance"));
end
