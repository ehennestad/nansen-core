function results = runExternalToolTests(toolsFolder)
%runExternalToolTests Run the ophys wrappers against the real tools, cloned into toolsFolder
%
%   Puts NoRMCorre, CaImAn-MATLAB, EXTRACT-public and flow_registration
%   (compiling its solver) on the path, and NANSEN dev's apps and code and the
%   Widgets Toolbox after this package (for imviewer), runs matlab/externaltests and fails unless every
%   test passed: a missing tool is a failure here, not a skip.
    thisDir = fileparts(mfilename("fullpath"));
    addpath(thisDir);
    addpath(fullfile(thisDir, "externaltests"));
    dsm = getenv("NANSEN_DSM_PATH");
    if dsm == ""
        dsm = fullfile(fileparts(thisDir), "dsm", "src", "matlab");
    end
    addpath(dsm);
    for name = ["NoRMCorre", "CaImAn-MATLAB", "EXTRACT-public"]
        addpath(genpath(fullfile(toolsFolder, name)));
    end
    flowreg = fullfile(toolsFolder, "flow_registration");
    addpath(fullfile(flowreg, "core"), fullfile(flowreg, "util"), fullfile(flowreg, "util", "io"));
    here = pwd;
    cd(fullfile(flowreg, "core"));
    make();   % compiles level_solver
    cd(here);
    % dev's apps (imviewer), its code and its bundled FileExchange code, with their own +nansen, go after this
    % package, so its functions are found first; then the Widgets Toolbox imviewer uses, with its jar
    dev = fullfile(toolsFolder, "NANSEN");
    addpath(fullfile(dev, "apps"), genpath(fullfile(dev, "code")), genpath(fullfile(dev, "external")), "-end");
    widgets = fullfile(toolsFolder, "widgets-toolbox");
    if isfolder(widgets)
        addpath(genpath(widgets), "-end");
        jars = dir(fullfile(widgets, "**", "*.jar"));
        for i = 1:numel(jars)
            javaaddpath(fullfile(jars(i).folder, jars(i).name));
        end
    end
    addpath(thisDir);
    results = run(matlab.unittest.TestSuite.fromFolder(fullfile(thisDir, "externaltests")));
    disp(table(results));
    assert(all([results.Passed]), "nansen:Tests:ExternalTools", "not every wrapper passed with its tool")
end
