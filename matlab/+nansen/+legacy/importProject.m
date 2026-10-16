function report = importProject(legacyFolder, folder, options)
%importProject Make a nansen-core project from a NANSEN dev project folder
%
%   report = nansen.legacy.importProject(legacyFolder, folder) reads the dev
%   project (nansen.legacy.exportProject) and writes a new project into the
%   empty folder (nansen.legacy.convert). The dev project is not changed.
%   report.warnings names everything that could not be carried over.
%
%   importProject(..., ExportFile=path) also keeps the intermediate export.
%   importProject(..., UserFolder=path) reads the user's dev preferences
%   (option presets of dev's methods, the task list, the local root paths,
%   the app's settings) from path, dev's nansen.prefdir; by default
%   prefdir/Nansen/default.
    arguments
        legacyFolder (1,1) string
        folder (1,1) string
        options.ExportFile (1,1) string = ""
        options.UserFolder (1,1) string = string(fullfile(prefdir, "Nansen", "default"))
    end
    export = nansen.legacy.exportProject(legacyFolder, File=options.ExportFile, UserFolder=options.UserFolder);
    report = nansen.legacy.convert(export, folder);
end
