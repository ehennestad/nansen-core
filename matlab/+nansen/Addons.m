classdef Addons
%Addons The add-on manager, as dev's AddonManager: the toolboxes and packages modules declare
%
%   A module lists them under addons in module.nansen.json. One from GitHub
%   is downloaded into the add-ons folder (~/.nansen/addons unless the
%   settings say otherwise) and put on the path, now and whenever an app
%   or API with a catalog starts; MATLAB does not install Python packages,
%   and says how to. Python's nansen.addons does the same for Python.

    properties (Constant)
        Marker = ".nansen-addon.json"
    end

    methods (Static)
        function folder = defaultFolder()
            home = string(getenv("HOME"));
            if home == ""
                home = string(getenv("USERPROFILE"));
            end
            folder = fullfile(home, ".nansen", "addons");
        end

        function found = declared(modules)
            %declared The add-ons the modules (a cell or row of nansen.Module) declare, each with its module
            if ~iscell(modules)
                modules = num2cell(modules);
            end
            found = {};
            ids = strings(1, 0);
            for i = 1:numel(modules)
                for addon = nansen.internal.asCellOfStructs(nansen.internal.getField(modules{i}.Document, "addons", []))
                    entry = addon{1};
                    if ~ismember(string(entry.id), ids)
                        entry.module = char(modules{i}.Id);
                        ids(end + 1) = string(entry.id); %#ok<AGROW>
                        found{end + 1} = entry; %#ok<AGROW>
                    end
                end
            end
        end

        function addon = find(addons, id)
            for i = 1:numel(addons)
                if string(addons{i}.id) == id
                    addon = addons{i};
                    return
                end
            end
            nansen.internal.throwError("unknown-addon", "no module of the project declares an add-on '%s'", id)
        end

        function result = status(addon, folder)
            %status What the add-on is and whether it is installed (true, false, or [] when MATLAB cannot tell)
            kinds = string(fieldnames(addon.source));
            kind = kinds(1);
            spec = string(addon.source.(kind));
            location = fullfile(folder, addon.id);
            downloaded = isfile(fullfile(location, nansen.Addons.Marker));
            if addon.language == "matlab"
                installed = downloaded || exist(addon.check) > 0 || ~isempty(which(addon.check)); %#ok<EXIST>
            else
                installed = [];
            end
            switch kind
                case "github"
                    how = "downloaded from https://github.com/" + spec + " into the add-ons folder";
                case "pip"
                    how = "pip install '" + spec + "'";
                otherwise
                    how = "conda install -c conda-forge " + spec;
            end
            where = [];
            if downloaded
                where = char(location);
            end
            result = struct("id", char(addon.id), "title", char(addon.title), ...
                "description", char(nansen.internal.getField(addon, "description", "")), ...
                "language", char(addon.language), "module", char(nansen.internal.getField(addon, "module", "")), ...
                "url", char(nansen.internal.getField(addon, "url", "")), "source", char(kind), "spec", char(spec), ...
                "check", char(addon.check), "installed", installed, "location", where, ...
                "installable", kind == "github", "removable", downloaded, "how", char(how));
        end

        function location = install(addon, folder, archive)
            %install Download a GitHub add-on (or unpack the local zip archive), put it on the path and run its setup
            arguments
                addon
                folder (1,1) string
                archive (1,1) string = ""
            end
            kinds = string(fieldnames(addon.source));
            if kinds(1) ~= "github"
                status = nansen.Addons.status(addon, folder);
                nansen.internal.throwError("install-failed", "%s is not installed by NANSEN in MATLAB; install it with: %s", ...
                    addon.title, status.how)
            end
            scratch = string(tempname);
            mkdir(scratch);
            cleanup = onCleanup(@() rmdir(scratch, "s"));
            if archive == ""
                archive = fullfile(scratch, "download.zip");
                try
                    websave(archive, "https://codeload.github.com/" + string(addon.source.github) + "/zip/HEAD");
                catch error
                    nansen.internal.throwError("install-failed", "cannot download %s: %s", addon.source.github, error.message)
                end
            end
            unpacked = fullfile(scratch, "unpacked");
            try
                unzip(archive, unpacked);
            catch
                nansen.internal.throwError("install-failed", "the download of %s is not a zip archive", addon.source.github)
            end
            entries = dir(unpacked);
            entries = entries(~ismember({entries.name}, [".", ".."]));
            top = unpacked;
            if numel(entries) == 1 && entries(1).isdir   % GitHub's archives hold one folder
                top = fullfile(unpacked, entries(1).name);
            end
            location = fullfile(folder, addon.id);
            if isfolder(location)
                rmpath(nansen.Addons.pathOf(location));
                rmdir(location, "s");
            end
            if ~isfolder(folder)
                mkdir(folder);
            end
            copyfile(top, location);
            marker = struct("id", addon.id, "source", addon.source, ...
                "pathOrder", char(nansen.internal.getField(addon, "pathOrder", "begin")), ...
                "setup", char(nansen.internal.getField(addon, "setup", "")));
            nansen.internal.writeText(fullfile(location, nansen.Addons.Marker), [jsonencode(marker, PrettyPrint=true), newline]);
            nansen.Addons.addOne(location);
            setup = string(marker.setup);
            if setup ~= ""
                run(fullfile(location, setup));   % in the script's own folder (run changes to it), as make.m expects
            end
        end

        function remove(addon, folder)
            %remove Take a downloaded add-on off the path and delete it
            location = fullfile(folder, addon.id);
            if ~isfile(fullfile(location, nansen.Addons.Marker))
                nansen.internal.throwError("install-failed", "%s was not downloaded into %s, so NANSEN does not remove it", addon.title, folder)
            end
            rmpath(nansen.Addons.pathOf(location));
            rmdir(location, "s");
        end

        function addToPath(folder)
            %addToPath Put every add-on downloaded into the folder on the path
            if ~isfolder(folder)
                return
            end
            for entry = reshape(dir(folder), 1, [])
                location = fullfile(entry.folder, entry.name);
                if entry.isdir && isfile(fullfile(location, nansen.Addons.Marker))
                    nansen.Addons.addOne(location);
                end
            end
        end
    end

    methods (Static, Access = private)
        function addOne(location)
            marker = jsondecode(nansen.internal.readText(fullfile(location, nansen.Addons.Marker)));
            folders = nansen.Addons.pathOf(location);
            if string(nansen.internal.getField(marker, "pathOrder", "begin")) == "end"
                addpath(folders, "-end");   % behind this NANSEN's functions
            else
                addpath(folders);
            end
        end

        function folders = pathOf(location)
            %pathOf The add-on's folder and its subfolders, as genpath gives them, without hidden ones
            parts = split(string(genpath(location)), pathsep);
            parts = parts(parts ~= "" & ~contains(parts, filesep + "."));
            folders = char(strjoin(parts, pathsep));
        end
    end
end
