function results = runExternalToolTests(toolsFolder)
%runExternalToolTests Run the ophys wrappers against the real tools, cloned into toolsFolder
%
%   Puts NoRMCorre, CaImAn-MATLAB, EXTRACT-public, matnwb, DeepInterpolation-MATLAB and flow_registration
%   (compiling its solver) on the path, and NANSEN dev's apps and code, the
%   Widgets Toolbox (for imviewer) and the MATLAB Suite2P after this package,
%   runs matlab/externaltests and fails unless every test passed: a missing
%   tool is a failure here, not a skip. Only a test that says by an
%   assumption why it cannot run here (DeepInterpolation without the Deep
%   Learning Toolbox) may be left incomplete.
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
    addpath(fullfile(toolsFolder, "DeepInterpolation-MATLAB"));   % its package, +deepinterp
    matnwb = fullfile(toolsFolder, "matnwb");
    addpath(matnwb);
    if exist("types.core.NWBFile", "class") ~= 8 && exist("matnwb.types.core.NWBFile", "class") ~= 8
        here = pwd;
        cd(matnwb);
        generateCore();   % the NWB core types, when the clone has none generated
        cd(here);
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
    % the MATLAB Suite2P last, as its add-on (pathOrder end): its run_pipeline is also CaImAn-MATLAB's
    addpath(genpath(fullfile(toolsFolder, "Suite2P")), "-end");
    addpath(thisDir);
    results = run(matlab.unittest.TestSuite.fromFolder(fullfile(thisDir, "externaltests")));
    disp(table(results));
    skipped = [results.Incomplete];
    if any(skipped)
        fprintf("Not run here (see each test's assumption): %s\n", strjoin(string({results(skipped).Name}), ", "));
    end
    assert(all([results.Passed] | skipped) && ~any([results.Failed]), "nansen:Tests:ExternalTools", ...
        "not every wrapper passed with its tool")
end
