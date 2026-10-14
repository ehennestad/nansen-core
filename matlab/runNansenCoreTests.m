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
    suite = matlab.unittest.TestSuite.fromFolder(fullfile(thisDir, "tests"));
    results = run(suite);
    disp(table(results))
    assertSuccess(results)
end
