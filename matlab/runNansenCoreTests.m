function results = runNansenCoreTests()
%runNansenCoreTests Run the MATLAB test suite: unit tests and every conformance case
%
%   results = runNansenCoreTests() adds the package to the path, runs every
%   test in matlab/tests, prints a summary and fails when any test fails.
    thisDir = fileparts(mfilename("fullpath"));
    addpath(thisDir);
    addpath(fullfile(thisDir, "tests"));
    % The existing NANSEN also uses +nansen; MATLAB would merge the two packages.
    packageFolders = string({what("nansen").path});
    others = packageFolders(~startsWith(packageFolders, thisDir));
    if ~isempty(others)
        error("nansen:Tests:OtherNansenOnPath", ...
            "Another +nansen package is on the path; run on a clean path (restoredefaultpath):\n%s", ...
            strjoin(others, newline))
    end
    addDsmReader(thisDir)
    suite = matlab.unittest.TestSuite.fromFolder(fullfile(thisDir, "tests"));
    % fromFolder only warns about a test file it cannot parse; leaving its tests out must fail the run
    files = dir(fullfile(thisDir, "tests", "*Test.m"));
    missing = setdiff(erase(string({files.name}), ".m"), string(unique({suite.TestParentName})));
    if ~isempty(missing)
        error("nansen:Tests:Excluded", "These test files define no tests that run: %s", strjoin(missing, ", "))
    end
    results = run(suite);
    fprintf("%d passed, %d failed, %d incomplete\n", nnz([results.Passed]), nnz([results.Failed]), ...
        nnz([results.Incomplete]));
    assertSuccess(results)
end

function addDsmReader(thisDir)
%addDsmReader Put the Dataset Structure Model's MATLAB reader on the path if it is not there
%
%   Looks in $NANSEN_DSM_PATH, then in a dataset-structure-model or dsm
%   checkout next to (or inside) this repository.
    if exist("dsm.walk", "file")
        return
    end
    root = fileparts(thisDir);
    candidates = [string(getenv("NANSEN_DSM_PATH")), ...
        fullfile(root, "dsm", "src", "matlab"), ...
        fullfile(fileparts(root), "dataset-structure-model", "src", "matlab")];
    for candidate = candidates
        if candidate ~= "" && isfolder(fullfile(candidate, "+dsm"))
            addpath(candidate)
            return
        end
    end
    error("nansen:Tests:NoDsmReader", ...
        "The DSM MATLAB reader (+dsm) is not on the path; set NANSEN_DSM_PATH to its src/matlab folder")
end
