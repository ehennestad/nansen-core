classdef Api < handle
%Api The app's API: JSON requests in, JSON responses and events out
%
%   api = nansen.Api(Catalog=nansen.Catalog(path)). response =
%   api.handle(request) takes a struct {id, method, params}; text =
%   api.handleJson(text) does the same on JSON text, which is what the
%   uihtml frontend sends. The methods and their results match the Python
%   nansen.api.Api (docs/reference/protocol.md). Listeners get events.

    properties (Constant)
        ProtocolVersion = "0.1"
    end

    properties (SetAccess = private)
        Catalog = []
        Project = []
        Queue = []
        % What view.frame, view.signal and view.traces may read, with no project: files and arrays handed to
        % nansen.view (a nansen.Viewables, registered from MATLAB, never by a request)
        Viewables = []
    end

    properties
        % Opens a folder in the system's file browser; tests put their own here
        OpenFolder function_handle = @nansen.Api.openInFileBrowser
        SendToWorkspace function_handle = @nansen.Api.assignInBase   % (name, value): where workspace.send puts entities
        OpenFile function_handle = @nansen.Api.openInFileBrowser   % opens a file in its default app
        OpenUrl function_handle = @(url) web(char(url), "-browser")   % opens a web page in the system's browser
        EditFile function_handle = @nansen.Api.openInEditor   % opens a code file in MATLAB's editor
        StartQueue (1,1) logical = false   % start the background worker whenever a project is opened (the app sets it)
    end

    properties (Access = private)
        Methods
        Listeners (1,:) cell = {}
    end

    methods
        function obj = Api(options)
            arguments
                options.Catalog = []
                options.Project = []
                options.Viewables = []
            end
            obj.Catalog = options.Catalog;
            obj.Viewables = options.Viewables;
            if isempty(obj.Viewables)
                obj.Viewables = nansen.Viewables();
            end
            obj.Methods = containers.Map("KeyType", "char", "ValueType", "any");
            names = ["app.info", "app.openUrl", "app.plugins", "workspace.send", "catalog.list", "catalog.relocate", "catalog.remove", "catalog.rename", "catalog.move", "catalog.install", "settings.get", "settings.save", "addons.list", "addons.install", "addons.remove", "project.open", "project.create", "project.info", ...
                "project.setDataset", "project.update", "scan.unmatched", "dataset.exclude", "dataset.assign", "dataset.unassign", "dataset.assignments", "dataset.test", "dataset.sample", "dataset.setRoot", "dataset.get", "dataset.save", "demo.create", "legacy.import", ...
                "project.scan", "project.sync", "entities.list", "entities.get", "entities.update", "entities.add", ...
                "entities.remove", "columns.reset", "fragments.detach", "notes.list", "notes.add", "notes.remove", "files.resolve", "files.list", "files.inspect", "files.frame", "files.send", "files.read", "files.makeFolder", "files.open", "files.reveal", "view.list", "view.frame", "view.signal", "view.traces", "views.list", "views.save", "views.delete", "fragments.list", "fragments.create", "fragments.save", "fragments.attach", "fragments.update", "dataVariables.list", "dataVariables.options", "adapters.create", "dataVariables.save", "dataVariables.delete", "data.status", "data.frame", "data.traces", "data.value", "data.send", "data.cache", "data.clearCache", "rois.update", "rois.detect", "rois.signal", "modules.list", "modules.add", "modules.remove", "modules.resource", "modules.data", "modules.saveData", ...
                "methods.list", "methods.setHidden", "methods.create", "methods.edit", "tools.list", "tools.run", "methods.run", "methods.preview", "presets.list", "presets.setDefault", "presets.save", "presets.delete", ...
                "pipelines.list", "pipelines.submit", "pipelines.save", "pipelines.delete", "pipelines.assign", "pipelines.markStep", "pipelines.queueNext", "pipelines.runNext", "tasks.submit", "tasks.comment", "tasks.list", "tasks.get", "tasks.cancel", "tasks.retry", "tasks.remove", "tasks.hold", "tasks.update", "tasks.reorder", ...
                "tasks.clear", "tasks.runNext", "queue.status", "queue.start", "queue.stop", "queue.startWorker"];
            for name = names
                % "entities.list" -> apiEntitiesList
                handler = "api" + join(arrayfun(@(p) upper(extractBefore(p, 2)) + extractAfter(p, 1), split(name, ".")'), "");
                obj.Methods(char(name)) = char(handler);
            end
            if ~isempty(obj.Catalog)
                nansen.Addons.addToPath(obj.addonsFolder());   % the add-ons downloaded before
            end
            if ~isempty(options.Project)
                obj.setProject(options.Project);
            end
        end

        function delete(obj)
            if ~isempty(obj.Queue)
                obj.Queue.stop();
            end
        end

        function names = methodNames(obj)
            names = sort(string(keys(obj.Methods)));
        end

        function response = handle(obj, request)
            %handle Answer one request struct with a struct {id, result} or {id, error}
            id = NaN;   % null
            if isstruct(request) && isfield(request, "id")
                id = request.id;
            end
            try
                if ~(isstruct(request) && isscalar(request) && isfield(request, "method"))
                    nansen.internal.throwError("invalid-request", "a request is an object with a method name")
                end
                name = char(request.method);
                if ~isKey(obj.Methods, name)
                    nansen.internal.throwError("unknown-api-method", "no API method '%s'", name)
                end
                params = nansen.internal.getField(request, "params", struct());
                if isempty(params)
                    params = struct();
                end
                if ~isstruct(params)
                    nansen.internal.throwError("invalid-params", "params must be an object")
                end
                result = obj.(obj.Methods(name))(params);
                response = struct("id", id, "result", {result});
            catch err
                if isa(err, "nansen.NansenError")
                    code = err.Code;
                    message = extractAfter(string(err.message), "] ");
                elseif err.identifier == "nansen:Api:MissingParameter"
                    code = "invalid-params";
                    message = string(err.message);
                else
                    code = "internal-error";
                    message = string(err.identifier) + ": " + string(err.message);
                end
                response = struct("id", id, "error", struct("code", char(code), "message", char(message)));
            end
        end

        function text = handleJson(obj, text)
            %handleJson Answer a JSON request with a JSON response
            try
                request = jsondecode(char(text));
            catch
                request = [];
            end
            text = string(jsonencode(obj.handle(request)));
        end

        function unsubscribe = subscribe(obj, listener)
            %subscribe Call listener(event) for every event (a struct with event and data)
            obj.Listeners{end + 1} = listener;
            index = numel(obj.Listeners);
            unsubscribe = @() obj.removeListener(index);
        end

        function emit(obj, event, data)
            message = struct("event", char(event), "data", data);
            for i = 1:numel(obj.Listeners)
                if ~isempty(obj.Listeners{i})
                    try
                        obj.Listeners{i}(message);
                    catch
                        % a broken listener must not stop the others
                    end
                end
            end
        end
    end

    % -- the API methods (names match the protocol: "entities.list" -> apiEntitiesList) --------------

    methods
        function result = apiAppOpenUrl(obj, params)
            % Open a web page (http or https) in the system's browser: the help pages, an issue report
            url = string(nansen.internal.getField(params, "url", ""));
            if ~isscalar(url) || isempty(regexp(url, "^https?://\S+$", "once"))
                nansen.internal.throwError("invalid-params", "'%s' is not an http or https address", strjoin(url, " "))
            end
            obj.OpenUrl(url);
            result = struct("url", char(url));
        end

        function result = apiAppInfo(obj, ~)
            result = struct("name", 'nansen', "language", 'matlab', "version", '0.1.0', ...
                "protocolVersion", char(nansen.Api.ProtocolVersion), "methods", {cellstr(obj.methodNames())}, ...
                "workspace", true);
        end

        function result = apiWorkspaceSend(obj, params)
            % Put the entities into the base workspace, as a cell row of nansen.Entity named name
            name = string(nansen.internal.getField(params, "name", "entities"));
            if ~isscalar(name) || ~isvarname(name)
                nansen.internal.throwError("invalid-params", "'%s' is not a variable name", strjoin(name, " "))
            end
            entities = obj.entities(params);
            obj.SendToWorkspace(name, entities);
            result = struct("name", char(name), "count", numel(entities));
        end

        function result = apiCatalogList(obj, ~)
            result = {};
            if ~isempty(obj.Catalog)
                result = obj.Catalog.projects();
            end
        end

        function result = apiAddonsList(obj, ~)
            % The add-ons the project's modules declare (the built-in modules' with no project open), and their state
            folder = obj.addonsFolder();
            result = struct("folder", char(folder), "language", "matlab", ...
                "addons", {cellfun(@(a) nansen.Addons.status(a, folder), obj.declaredAddons(), UniformOutput=false)});
        end

        function result = apiAddonsInstall(obj, params)
            folder = obj.addonsFolder();
            addon = nansen.Addons.find(obj.declaredAddons(), string(nansen.Api.param(params, "id")));
            nansen.Addons.install(addon, folder, string(nansen.internal.getField(params, "archive", "")));
            result = nansen.Addons.status(addon, folder);
        end

        function result = apiAddonsRemove(obj, params)
            folder = obj.addonsFolder();
            addon = nansen.Addons.find(obj.declaredAddons(), string(nansen.Api.param(params, "id")));
            nansen.Addons.remove(addon, folder);
            result = nansen.Addons.status(addon, folder);
        end

        function result = apiSettingsGet(obj, ~)
            if isempty(obj.Catalog)
                result = nansen.Catalog.defaultSettings();
            else
                result = obj.Catalog.settings();
            end
        end

        function result = apiSettingsSave(obj, params)
            if isempty(obj.Catalog)
                nansen.internal.throwError("no-catalog", "this app has no project catalog to keep settings in")
            end
            result = obj.Catalog.saveSettings(nansen.Api.param(params, "settings"));
            if ~isempty(obj.Queue)
                obj.Queue.Worker = result.queue.worker;   % from the next task on
            end
        end

        function result = apiCatalogRelocate(obj, params)
            % A project was moved: point its entry at the new folder
            if isempty(obj.Catalog)
                nansen.internal.throwError("no-catalog", "this app has no project catalog")
            end
            obj.Catalog.relocate(string(nansen.Api.param(params, "path")), string(nansen.Api.param(params, "newPath")));
            result = obj.Catalog.projects();
        end

        function result = apiCatalogInstall(obj, params)
            % A project shared in a git repository (on GitHub, say) cloned into a folder and added to the catalog,
            % as dev's installProject; the folder must hold a project once cloned
            if isempty(obj.Catalog)
                nansen.internal.throwError("no-catalog", "this app has no project catalog")
            end
            url = string(nansen.Api.param(params, "url"));
            folder = string(nansen.Api.param(params, "path"));
            if isfolder(folder) && numel(dir(folder)) > 2
                nansen.internal.throwError("folder-not-empty", "%s is not empty", folder)
            end
            [status, ~] = system("git --version");
            if status ~= 0
                nansen.internal.throwError("dependency-missing", "installing a project needs git")
            end
            [status, output] = system(sprintf('git clone --depth 1 -- "%s" "%s" 2>&1', url, folder));
            if status ~= 0
                nansen.internal.throwError("install-failed", "git could not clone %s: %s", url, strtrim(output))
            end
            try
                project = nansen.Project.open(folder);
            catch err
                nansen.internal.throwError("not-a-project", "%s holds no NANSEN project (%s); it was cloned to %s", url, err.message, folder)
            end
            obj.Catalog.add(project, false);
            result = obj.Catalog.projects();
        end

        function result = apiCatalogRemove(obj, params)
            % Forget a project; with deleteFolder, delete its folder too (dev's project manager's Delete), which must
            % hold the project, and not be the project open
            if isempty(obj.Catalog)
                nansen.internal.throwError("no-catalog", "this app has no project catalog")
            end
            folder = nansen.Catalog.absolute(string(nansen.Api.param(params, "path")));
            deleteFolder = logical(nansen.internal.getField(params, "deleteFolder", false));
            if deleteFolder
                obj.notOpen(folder);
                if ~isfile(fullfile(folder, "project.nansen.json"))
                    nansen.internal.throwError("invalid-params", "%s holds no project, so it is not deleted", folder)
                end
            end
            obj.Catalog.remove(folder);
            if deleteFolder
                rmdir(folder, "s");
            end
            result = obj.Catalog.projects();
        end

        function result = apiCatalogRename(obj, params)
            % Give a project another name (dev's project manager's Rename): in its project.nansen.json and the catalog
            if isempty(obj.Catalog)
                nansen.internal.throwError("no-catalog", "this app has no project catalog")
            end
            folder = nansen.Catalog.absolute(string(nansen.Api.param(params, "path")));
            obj.Catalog.rename(folder, nansen.Api.param(params, "name"));
            if ~isempty(obj.Project) && nansen.Catalog.absolute(obj.Project.Folder) == folder   % the open one: read it again
                obj.setProject(nansen.Project.open(folder, Environment=obj.Project.Environment));
                obj.emit("project", struct("name", char(obj.Project.Name)));
            end
            result = obj.Catalog.projects();
        end

        function result = apiCatalogMove(obj, params)
            % Move a project's folder (dev's project manager's Move): to newPath, which must not exist, and point the
            % catalog there. Not the project open
            if isempty(obj.Catalog)
                nansen.internal.throwError("no-catalog", "this app has no project catalog")
            end
            folder = nansen.Catalog.absolute(string(nansen.Api.param(params, "path")));
            target = nansen.Catalog.absolute(string(nansen.Api.param(params, "newPath")));
            obj.notOpen(folder);
            if ~isfolder(folder)
                nansen.internal.throwError("file-not-found", "%s does not exist", folder)
            end
            if isfolder(target) || isfile(target)
                nansen.internal.throwError("folder-not-empty", "%s exists already", target)
            end
            if target == folder || startsWith(target, folder + filesep)
                nansen.internal.throwError("invalid-params", "%s is inside %s", target, folder)
            end
            parent = fileparts(target);
            if ~isfolder(parent)
                mkdir(parent);
            end
            [ok, message] = movefile(folder, target);
            if ~ok
                nansen.internal.throwError("invalid-params", "could not move %s: %s", folder, message)
            end
            obj.Catalog.relocate(folder, target);
            result = obj.Catalog.projects();
        end

        function notOpen(obj, folder)
            if ~isempty(obj.Project) && nansen.Catalog.absolute(obj.Project.Folder) == folder
                nansen.internal.throwError("invalid-params", "that is the project open: open another one first")
            end
        end

        function result = apiProjectOpen(obj, params)
            environment = string(nansen.internal.getField(params, "environment", ""));
            obj.setProject(nansen.Project.open(nansen.Api.param(params, "path"), Environment=environment));
            obj.emit("project", struct("name", char(obj.Project.Name)));
            result = obj.apiProjectInfo(struct());
        end

        function result = apiProjectCreate(obj, params)
            % A new project; with datasetSource, a copy of that DSM config, and with entityTypes, its entity types
            source = string(nansen.internal.getField(params, "datasetSource", ""));
            if source ~= ""
                nansen.Dataset.load(source, "");   % file-not-found or dataset-invalid before anything is written
            end
            project = nansen.Project.create(nansen.Api.param(params, "path"), nansen.Api.param(params, "name"), ...
                Title=string(nansen.internal.getField(params, "title", "")), ...
                Dataset=string(nansen.internal.getField(params, "dataset", "")), ...
                Description=string(nansen.internal.getField(params, "description", "")));
            nansen.Api.configure(project, params);
            obj.setProject(project);
            obj.emit("project", struct("name", char(project.Name)));
            result = obj.apiProjectInfo(struct());
        end

        function result = apiProjectSetDataset(obj, params)
            % Give the open project a copy of a DSM config; also add modules, and with entityTypes, its entity types
            project = obj.requireProject();
            nansen.Api.configure(project, params);
            obj.setProject(nansen.Project.open(project.Folder, Environment=project.Environment));
            obj.emit("project", struct("name", char(obj.Project.Name)));
            result = obj.apiProjectInfo(struct());
        end

        function result = apiDatasetSetRoot(obj, params)
            % Where a data location is on this machine (or in the given environment)
            project = obj.requireProject();
            project.setRoot(string(nansen.Api.param(params, "dataLocation")), string(nansen.Api.param(params, "path")), ...
                Environment=string(nansen.internal.getField(params, "environment", "")), ...
                RootStoragePath=string(nansen.internal.getField(params, "rootStoragePath", "")));
            obj.setProject(nansen.Project.open(project.Folder, Environment=project.Environment));
            obj.emit("project", struct("name", char(obj.Project.Name)));
            result = obj.apiProjectInfo(struct());
        end

        function result = apiProjectUpdate(obj, params)
            % Change the project's title or description, or entity types' titles
            project = obj.requireProject();
            options = struct();
            if isfield(params, "title")
                options.Title = string(params.title);
            end
            if isfield(params, "description")
                options.Description = string(params.description);
            end
            if isfield(params, "entityTypeTitles") && isstruct(params.entityTypeTitles)
                options.EntityTypeTitles = params.entityTypeTitles;
            end
            args = namedargs2cell(options);
            project.updateInfo(args{:});
            if ~isempty(obj.Catalog)
                obj.Catalog.add(project);
            end
            obj.emit("project", struct("name", char(project.Name)));
            result = obj.apiProjectInfo(struct());
        end

        function result = apiScanUnmatched(obj, params)
            % What the last scan found that no entity accounts for: each with its location, path, reason and detail
            project = obj.requireProject();
            scan = project.lastScan();
            result = struct("scannedAt", NaN, "total", 0, "entries", {{}});
            if isempty(scan)
                return
            end
            entries = nansen.Api.unmatchedOf(scan);
            keys = strings(1, numel(entries));   % the readers emit them in their own order
            for i = 1:numel(entries)
                keys(i) = string(nansen.internal.getField(entries{i}, "dataLocationIdentifier", "")) + char(0) + ...
                    string(nansen.internal.getField(entries{i}, "path", ""));
            end
            [~, order] = sort(keys);
            entries = entries(order);
            limit = double(nansen.internal.getField(params, "limit", 1000));
            shown = cell(1, min(limit, numel(entries)));
            dataset = project.dataset();
            for i = 1:numel(shown)
                u = entries{i};
                entry = struct("dataLocation", char(nansen.internal.getField(u, "dataLocationIdentifier", "")), ...
                    "rootStoragePath", char(nansen.internal.getField(u, "rootStoragePathIdentifier", "")), ...
                    "path", char(nansen.internal.getField(u, "path", "")), "reason", char(nansen.internal.getField(u, "reason", "")), ...
                    "detail", char(nansen.internal.getField(u, "detail", "")), "entityType", NaN, "key", NaN);
                if ~isempty(dataset)
                    % what it could be matched to by hand, and what its names say of the key
                    [entityType, key] = dataset.suggestedKey(entry.dataLocation, entry.rootStoragePath, entry.path);
                    entry.entityType = entityType;
                    entry.key = key;
                end
                shown{i} = entry;
            end
            result = struct("scannedAt", char(scan.ScannedAt), "total", numel(entries), "entries", {shown});
        end

        function result = apiDatasetExclude(obj, params)
            % Skip an unmatched entry in later scans, by its exact name at its level
            project = obj.requireProject();
            result = project.excludeFromScan(string(nansen.Api.param(params, "dataLocation")), string(nansen.Api.param(params, "path")));
            obj.reopen(project);
        end

        function result = apiDatasetAssign(obj, params)
            % Match an entry of a data location to an entity by hand, from the next scan on (dev's FolderMatcherDialog)
            project = obj.requireProject();
            key = nansen.Api.param(params, "key");
            if ~(isstruct(key) && isscalar(key))
                nansen.internal.throwError("invalid-params", "key is an object of the entity's key values")
            end
            result = project.assignEntry(string(nansen.Api.param(params, "dataLocation")), ...
                string(nansen.Api.param(params, "path")), key);
            obj.emit("project", struct("name", char(project.Name)));
        end

        function result = apiDatasetUnassign(obj, params)
            % Undo the matching of an entry to an entity by hand
            project = obj.requireProject();
            removed = project.unassignEntry(string(nansen.Api.param(params, "dataLocation")), string(nansen.Api.param(params, "path")));
            obj.emit("project", struct("name", char(project.Name)));
            result = struct("removed", removed);
        end

        function result = apiDatasetAssignments(obj, ~)
            % The entries matched to an entity by hand
            result = obj.requireProject().assignments();
        end

        function result = apiDatasetTest(obj, params)
            % What a scan with a candidate DSM config (its text) would find, without keeping anything
            result = obj.requireProject().testDatasetText(string(nansen.Api.param(params, "text")));
        end

        function result = apiDatasetSample(obj, params)
            % Example names at each folder level under a folder: up to limit names per level, from up to limit folders above
            path = string(nansen.Api.param(params, "path"));
            if startsWith(path, "~")
                path = fullfile(char(java.lang.System.getProperty("user.home")), extractAfter(path, 1));
            end
            if ~startsWith(path, ["/", "\"]) && isempty(regexp(path, "^[A-Za-z]:", "once"))
                if isempty(obj.Project)
                    nansen.internal.throwError("invalid-params", "a relative path needs an open project")
                end
                path = fullfile(obj.Project.Folder, path);
            end
            path = string(path);
            if ~isfolder(path)
                nansen.internal.throwError("file-not-found", "%s is not a folder", path)
            end
            depth = double(nansen.internal.getField(params, "depth", 4));
            limit = double(nansen.internal.getField(params, "limit", 8));
            levels = {};
            folders = path;
            for d = 1:depth
                names = strings(1, 0);
                files = 0;
                nextFolders = strings(1, 0);
                for f = folders(1:min(limit, numel(folders)))
                    listing = dir(f);
                    listing = listing(~ismember({listing.name}, {'.', '..'}));
                    [~, order] = sort(string({listing.name}));
                    listing = listing(order);
                    for k = 1:numel(listing)
                        if listing(k).isdir
                            nextFolders(end + 1) = string(fullfile(f, listing(k).name)); %#ok<AGROW>
                            if ~ismember(string(listing(k).name), names)
                                names(end + 1) = string(listing(k).name); %#ok<AGROW>
                            end
                        else
                            files = files + 1;
                        end
                    end
                end
                if isempty(names) && files == 0
                    break
                end
                levels{end + 1} = struct("folders", {cellstr(names(1:min(limit, end)))}, ...
                    "moreFolders", max(0, numel(names) - limit), "files", files); %#ok<AGROW>
                folders = nextFolders;
                if isempty(folders)
                    break
                end
            end
            result = struct("path", char(path), "levels", {levels});
        end

        function result = apiDatasetGet(obj, ~)
            % The DSM config's text, for editing
            project = obj.requireProject();
            text = project.datasetText();
            result = struct("path", char(project.Document.dataset), "text", char(text));
        end

        function result = apiDatasetSave(obj, params)
            % Replace the DSM config's text; refused (and nothing changed) unless DSM accepts it and the keys still match
            project = obj.requireProject();
            project.saveDatasetText(string(nansen.Api.param(params, "text")));
            result = obj.reopen(project);
        end

        function result = apiDemoCreate(obj, params)
            % A demo project in a new folder, now open: kind sessions (the default) or two-photon (the quickstart)
            path = nansen.Api.param(params, "path");
            kind = nansen.internal.getField(params, "kind", "sessions");
            if ~(ischar(kind) || isstring(kind)) || ~ismember(string(kind), ["sessions", "two-photon"])
                nansen.internal.throwError("invalid-params", "kind is one of sessions, two-photon, not %s", jsonencode(kind))
            elseif string(kind) == "sessions"
                project = nansen.demo.create(path);
            else
                project = nansen.demo.createTwoPhoton(path);
            end
            obj.setProject(project);
            obj.emit("project", struct("name", char(obj.Project.Name)));
            result = obj.apiProjectInfo(struct());
        end

        function result = apiLegacyImport(obj, params)
            % A project from a NANSEN dev project folder, or from the JSON export of one
            source = string(nansen.Api.param(params, "source"));
            folder = string(nansen.Api.param(params, "path"));
            if isfolder(source)
                report = nansen.legacy.importProject(source, folder);
            elseif isfile(source)
                report = nansen.legacy.convert(nansen.internal.readJson(source), folder);
            else
                nansen.internal.throwError("file-not-found", "no file or folder %s", source)
            end
            obj.setProject(nansen.Project.open(folder));
            obj.emit("project", struct("name", char(obj.Project.Name)));
            result = struct("project", obj.apiProjectInfo(struct()), "warnings", {report.warnings});
        end

        function result = apiProjectInfo(obj, ~)
            project = obj.requireProject();
            dataset = project.dataset();
            scan = project.lastScan();
            entityTypes = {};
            for entry = project.Document.entityTypes
                item = entry{1};
                name = string(item.name);
                try
                    rows = project.table(name).numRows();
                catch
                    rows = NaN;
                end
                records = NaN;
                if ~isempty(scan)
                    records = numel(scan.recordsOf(name));
                end
                title = char(nansen.internal.getField(item, "title", ""));
                if isempty(title)
                    title = char(upper(extractBefore(name, 2)) + extractAfter(name, 1));
                end
                entityTypes{end + 1} = struct("name", char(name), "title", title, ...
                    "fragments", {nansen.internal.asCellstr(nansen.internal.getField(item, "fragments", {}))}, ...
                    "rows", rows, "records", records); %#ok<AGROW>
            end
            modules = arrayfun(@(m) m.summary(), project.modules(), UniformOutput=false);
            lastScan = NaN;
            if ~isempty(scan)
                lastScan = char(scan.ScannedAt);
            end
            result = struct("name", char(project.Name), "title", char(project.Title), "folder", char(project.Folder), ...
                "description", char(nansen.internal.getField(project.Document, "description", "")), ...
                "entityTypes", {entityTypes}, "modules", {modules}, "lastScan", lastScan, "dataset", NaN);
            if ~isempty(dataset)
                locations = cellfun(@(l) struct("id", l.identifier, ...
                    "title", char(nansen.internal.getField(l, "displayName", l.identifier)), ...
                    "category", char(nansen.internal.getField(l, "dataCategory", "")), ...
                    "access", char(nansen.internal.getField(l, "access", "read"))), dataset.Config.locations(), UniformOutput=false);
                roots = arrayfun(@(r) struct("dataLocation", char(r.DataLocation), "rootStoragePath", char(r.RootStoragePath), ...
                    "path", char(r.Path), "environment", nansen.Api.nullIfEmpty(r.Environment), "available", r.Available), ...
                    dataset.roots(), UniformOutput=false);
                result.dataset = struct("environment", nansen.Api.nullIfEmpty(dataset.Environment), ...
                    "entityTypes", {cellstr(dataset.entityTypes())}, "locations", {locations}, "roots", {roots});
            end
        end

        function result = apiProjectScan(obj, params)
            project = obj.requireProject();
            listing = [];
            if isfield(params, "listing")
                listing = dsm.Listing.fromStruct(params.listing);
            end
            scan = project.scan(listing);
            counts = struct();
            for i = 1:numel(scan.Records)
                name = string(scan.Records{i}.entityType);
                counts.(name) = nansen.internal.getField(counts, name, 0) + 1;
            end
            result = struct("scannedAt", char(scan.ScannedAt), "records", counts, "roots", {scan.Roots}, ...
                "unmatched", numel(nansen.Api.unmatchedOf(scan)));
            obj.emit("scan", result);
        end

        function result = apiProjectSync(obj, params)
            project = obj.requireProject();
            names = project.EntityTypes;
            if isfield(params, "entityType")
                names = string(params.entityType);
            end
            added = struct();
            for name = names
                added.(name) = project.sync(name);
            end
            obj.emit("entities", struct("entityTypes", {cellstr(names)}));
            result = struct("added", added);
        end

        function result = apiEntitiesList(obj, params)
            project = obj.requireProject();
            entityType = string(nansen.Api.param(params, "entityType"));
            table = project.table(entityType);
            entities = project.entities(entityType);
            % The first entities are the table's rows, in table order: convert the table once.
            jsonRows = table.toJsonRows();
            rows = cell(1, numel(entities));
            for i = 1:numel(entities)
                if i <= numel(jsonRows)
                    rows{i} = obj.row(entities{i}, table, jsonRows{i});
                else
                    rows{i} = obj.row(entities{i}, table);
                end
            end
            columns = obj.columns(entityType, table);
            if obj.hasPipelines(project, entityType)
                progress = project.pipelineProgress(entityType);
                columns{end + 1} = struct("name", 'progress', "dataType", 'number', "title", 'Progress', "unit", NaN, ...
                    "fragment", 'core.pipeline', "source", 'progress', "editable", false);
                for i = 1:numel(rows)
                    [rows{i}.values.progress, state] = nansen.Api.progressOf(progress, rows{i}.key);
                    if ~isempty(state)
                        rows{i}.progress = struct("pipeline", state.pipeline, "title", state.title, ...
                            "done", state.done, "total", state.total);
                    end
                end
            end
            % dev's Notebook column: each entity's notes, and how many of each kind
            counts = containers.Map("KeyType", "char", "ValueType", "any");
            for note = project.notebook(entityType).notes([])
                id = char(nansen.internal.runKeyId(note{1}.key));
                if ~isKey(counts, id)
                    counts(id) = struct("count", 0, "important", 0, "todo", 0, "question", 0);
                end
                count = counts(id);
                count.count = count.count + 1;
                kind = string(nansen.internal.getField(note{1}, "type", ""));
                if ismember(kind, ["important", "todo", "question"])
                    count.(kind) = count.(kind) + 1;
                end
                counts(id) = count;
            end
            for i = 1:numel(rows)
                id = char(nansen.internal.runKeyId(rows{i}.key));
                if isKey(counts, id)
                    rows{i}.notes = counts(id);
                end
            end
            result = struct("entityType", char(entityType), "key", {cellstr(table.Key)}, ...
                "columns", {columns}, "rows", {rows});
        end

        function result = apiEntitiesGet(obj, params)
            project = obj.requireProject();
            entity = obj.entity(params);
            table = project.table(entity.EntityType);
            result = obj.row(entity, table);
            result.entityType = char(entity.EntityType);
            result.locations = entity.locations();
            result.issueDetails = entity.Issues;
            result.data = {};
            if ~isempty(project.dataset())
                result.data = project.dataStatus(entity);
            end
            if obj.hasPipelines(project, entity.EntityType)
                [result.values.progress, state] = nansen.Api.progressOf(project.pipelineProgress(entity.EntityType), entity.Key);
                if ~isempty(state)
                    result.pipeline = state;
                end
            end
        end

        function result = apiEntitiesUpdate(obj, params)
            project = obj.requireProject();
            entityType = string(nansen.Api.param(params, "entityType"));
            table = project.table(entityType);
            key = nansen.Api.param(params, "key");
            if ~table.hasRow(key)
                nansen.internal.throwError("unknown-entity", "no row with this key")
            end
            values = nansen.Api.param(params, "values");
            columns = obj.columns(entityType, table);
            editable = string(cellfun(@(c) c.name, columns(cellfun(@(c) c.editable, columns)), UniformOutput=false));
            for name = reshape(string(fieldnames(values)), 1, [])
                if ~ismember(name, editable)
                    nansen.internal.throwError("read-only-column", "column '%s' cannot be edited", name)
                end
            end
            project.checkChoices(entityType, values);
            table.updateRow(key, values);
            table.write();
            obj.emit("entities", struct("entityTypes", {{char(entityType)}}, "keys", {{key}}));
            entity = project.entity(entityType, key);
            result = obj.row(entity, project.table(entityType));
            if ~isempty(obj.Catalog) && obj.Catalog.settings().tables.saveToDataFolders
                obj.saveToDataFolders(entity, result);
            end
        end

        function saveToDataFolders(obj, entity, row)
            % The row as <entity type>_info.json in each of the entity's folders, as dev's AutosaveMetadataToDataFolders
            text = [jsonencode(row.values, PrettyPrint=true), newline];
            locations = nansen.internal.asCellOfStructs(entity.locations());
            for i = 1:numel(locations)
                location = locations{i};
                for path = reshape(string(location.paths), 1, [])
                    try
                        folder = obj.apiFilesResolve(struct("dataLocation", location.dataLocationIdentifier, ...
                            "rootStoragePath", nansen.internal.getField(location, "rootStoragePathIdentifier", ""), "path", path));
                    catch
                        continue   % a root not on this computer
                    end
                    if folder.isFolder
                        nansen.internal.writeText(fullfile(folder.path, entity.EntityType + "_info.json"), text);
                    end
                end
            end
        end

        function result = apiEntitiesAdd(obj, params)
            project = obj.requireProject();
            entityType = string(nansen.Api.param(params, "entityType"));
            key = nansen.Api.param(params, "key");
            row = nansen.internal.mergeStructs(key, nansen.internal.getField(params, "values", struct()));
            table = project.table(entityType);
            project.checkChoices(entityType, nansen.internal.getField(params, "values", struct()));
            table.addRow(row);
            table.write();
            obj.emit("entities", struct("entityTypes", {{char(entityType)}}));
            result = obj.row(project.entity(entityType, key), project.table(entityType));
        end

        function result = apiEntitiesRemove(obj, params)
            project = obj.requireProject();
            table = project.table(string(nansen.Api.param(params, "entityType")));
            table.removeRow(nansen.Api.param(params, "key"));
            table.write();
            obj.emit("entities", struct("entityTypes", {{char(params.entityType)}}));
            result = struct("removed", params.key);
        end

        function result = apiViewsList(obj, params)
            result = obj.requireProject().views(string(nansen.Api.param(params, "entityType"))).list();
        end

        function result = apiViewsSave(obj, params)
            entityType = string(nansen.Api.param(params, "entityType"));
            result = obj.requireProject().views(entityType).save(nansen.Api.param(params, "view"));
            obj.emit("views", struct("entityType", char(entityType)));
        end

        function result = apiViewsDelete(obj, params)
            entityType = string(nansen.Api.param(params, "entityType"));
            name = string(nansen.Api.param(params, "name"));
            obj.requireProject().views(entityType).remove(name);
            obj.emit("views", struct("entityType", char(entityType)));
            result = struct("removed", char(name));
        end

        function result = apiFilesResolve(obj, params)
            project = obj.requireProject();
            relative = string(nansen.internal.getField(params, "path", ""));
            if startsWith(relative, ["/", "\"]) || ~isempty(regexp(relative, "^[A-Za-z]:", "once"))
                nansen.internal.throwError("invalid-params", "'%s' is not a relative path", relative)
            end
            if isfield(params, "dataLocation")
                rootPath = "";
                if isfield(params, "rootStoragePath")
                    rootPath = string(params.rootStoragePath);
                end
                base = project.requireDataset().root(string(params.dataLocation), rootPath).Path;
            else
                base = project.Folder;
            end
            base = regexprep(nansen.internal.normalizePath(base), "(?<=.)/$", "");
            path = nansen.internal.normalizePath(base + "/" + relative);
            if path ~= base && ~startsWith(path, regexprep(base, "/$", "") + "/")
                nansen.internal.throwError("invalid-params", "'%s' is outside %s", relative, base)
            end
            native = replace(path, "/", filesep);
            result = struct("path", char(native), "exists", isfile(native) || isfolder(native), "isFolder", isfolder(native));
        end

        function result = apiFilesList(obj, params)
            % What a folder holds, as files.resolve finds it: folders first, then files, each by name
            result = obj.apiFilesResolve(params);
            if ~result.exists
                nansen.internal.throwError("file-not-found", "%s does not exist", result.path)
            end
            if ~result.isFolder
                nansen.internal.throwError("invalid-params", "%s is not a folder", result.path)
            end
            limit = double(nansen.internal.getField(params, "limit", 500));
            listing = dir(result.path);
            listing = listing(~ismember({listing.name}, {'.', '..'}));
            keys = strings(1, numel(listing));
            for i = 1:numel(listing)
                keys(i) = string(double(~listing(i).isdir)) + "/" + string(listing(i).name);   % folders first, then by name
            end
            [~, order] = sort(keys);
            listing = listing(order);
            entries = cell(1, min(numel(listing), limit));
            for i = 1:numel(entries)
                item = listing(i);
                bytes = item.bytes;
                if item.isdir
                    bytes = NaN;   % null
                end
                modified = datetime(item.datenum, ConvertFrom="datenum", Format="yyyy-MM-dd'T'HH:mm:ss");
                entries{i} = struct("name", item.name, "isFolder", logical(item.isdir), "size", bytes, ...
                    "modified", char(modified));
            end
            result.entries = entries;
            result.truncated = numel(listing) > limit;
        end

        function result = apiFilesInspect(obj, params)
            % The groups, datasets and links of an HDF5 file (NWB, MATLAB v7.3, .h5), as files.resolve finds it
            result = obj.apiFilesResolve(params);
            if ~result.exists
                nansen.internal.throwError("file-not-found", "%s does not exist", result.path)
            end
            if result.isFolder
                nansen.internal.throwError("invalid-params", "%s is a folder; files.list shows folders", result.path)
            end
            layout = nansen.internal.inspectHdf5(result.path, double(nansen.internal.getField(params, "limit", 2000)));
            result.format = layout.format;
            result.items = layout.items;
            result.truncated = layout.truncated;
        end

        function result = apiFilesRead(obj, params)
            % The start of a file as text, as dev's file viewer's preview: at most maxBytes (default 65536) bytes,
            % decoded as UTF-8 (bytes that are not are replaced); binary when it has a NUL byte
            result = obj.apiFilesResolve(params);
            if ~result.exists
                nansen.internal.throwError("file-not-found", "%s does not exist", result.path)
            end
            if result.isFolder
                nansen.internal.throwError("invalid-params", "%s is a folder", result.path)
            end
            limit = double(nansen.internal.getField(params, "maxBytes", 65536));
            fid = fopen(result.path, "r");
            closer = onCleanup(@() fclose(fid));
            data = fread(fid, limit + 1, "*uint8")';
            listing = dir(result.path);
            result.binary = any(data(1:min(end, limit)) == 0);
            result.text = '';
            if ~result.binary
                result.text = char(native2unicode(data(1:min(end, limit)), "UTF-8"));
            end
            result.truncated = numel(data) > limit;
            result.size = listing.bytes;
        end

        function result = apiFilesMakeFolder(obj, params)
            % A new folder, as files.resolve finds it (in the project folder or a data location's root)
            result = obj.apiFilesResolve(params);
            if result.exists
                nansen.internal.throwError("invalid-params", "%s exists already", result.path)
            end
            mkdir(result.path);
            result.exists = true;
            result.isFolder = true;
        end

        function result = apiFilesSend(obj, params)
            % Read any file and put its value in the base workspace, as dev's file viewer's Load to workspace: with the
            % adapter given, or the first of those naming its extension that reads it
            project = obj.requireProject();
            resolved = obj.apiFilesResolve(params);
            if ~resolved.exists
                nansen.internal.throwError("file-not-found", "%s does not exist", resolved.path)
            end
            if resolved.isFolder
                nansen.internal.throwError("invalid-params", "%s is a folder", resolved.path)
            end
            [~, stem, extension] = fileparts(string(resolved.path));
            name = string(nansen.internal.getField(params, "name", ""));
            if name == ""
                name = regexprep(stem, "\W", "_");
                if name == "" || ~isletter(extractBefore(name, 2))
                    name = "data_" + name;
                end
            end
            if ~isvarname(name)
                nansen.internal.throwError("invalid-params", "'%s' is not a variable name", name)
            end
            adapterId = string(nansen.internal.getField(params, "adapter", ""));
            tries = adapterId;
            if adapterId == ""
                tries = project.adapters().forExtension(extension);
            end
            if isempty(tries)
                nansen.internal.throwError("unsupported-file", "no file adapter of the project reads %s files", extension)
            end
            problems = strings(1, 0);
            for candidate = tries
                try
                    value = project.adapters().get(candidate).read(string(resolved.path));
                catch err
                    if adapterId ~= "" || ~startsWith(string(err.identifier), "nansen:")
                        rethrow(err)
                    end
                    problems(end + 1) = candidate + ": " + string(err.message); %#ok<AGROW>
                    continue
                end
                obj.SendToWorkspace(name, value);
                result = struct("name", char(name), "adapter", char(candidate), "path", char(resolved.path));
                return
            end
            nansen.internal.throwError("invalid-data", "%s could not be read: %s", stem + extension, strjoin(problems, "; "))
        end

        function result = apiFilesFrame(obj, params)
            % A frame (or a projection) of any stack file, as data.frame gives one of a variable: dev's imviewer on a
            % file. The adapter is the one given, or the first that reads the file (Project.openFileStack)
            project = obj.requireProject();
            resolved = obj.apiFilesResolve(params);
            if ~resolved.exists
                nansen.internal.throwError("file-not-found", "%s does not exist", resolved.path)
            end
            if resolved.isFolder
                nansen.internal.throwError("invalid-params", "%s is a folder", resolved.path)
            end
            limits = nansen.internal.getField(params, "limits", []);
            if ~isempty(limits) && (~isnumeric(limits) || numel(limits) ~= 2)
                nansen.internal.throwError("invalid-params", "limits is [low, high]")
            end
            [stack, adapterId, candidates] = project.openFileStack(string(resolved.path), string(nansen.internal.getField(params, "adapter", "")));
            result = nansen.internal.imageFrame(stack, ...
                double(nansen.internal.getField(params, "frame", 0)), double(nansen.internal.getField(params, "channel", 0)), ...
                string(nansen.internal.getField(params, "projection", "")), double(limits), ...
                double(nansen.internal.getField(params, "plane", 0)), string(nansen.internal.getField(params, "filter", "")), ...
                nansen.Api.binOf(params));
            result.metadata = stack.Metadata;
            result.adapter = char(adapterId);
            result.adapters = cellstr(candidates);
            [~, name, extension] = fileparts(string(resolved.path));
            result.name = char(name + extension);
        end

        % -- viewing without a project: what nansen.view registered ---------------------------------------------------

        function result = apiViewList(obj, ~)
            % The files and arrays this app was given to view: {id, kind (stack or signals), name, path, rois}
            result = obj.Viewables.list();
        end

        function result = apiViewFrame(obj, params)
            % A frame (or a projection) of a registered stack, as files.frame gives one of a file; with rois, its ROIs of
            % the plane and channel shown. No project is needed, and nothing but what was registered is read
            item = obj.Viewables.get(nansen.Api.param(params, "viewable"));
            limits = nansen.internal.getField(params, "limits", []);
            if ~isempty(limits) && (~isnumeric(limits) || numel(limits) ~= 2)
                nansen.internal.throwError("invalid-params", "limits is [low, high]")
            end
            [stack, adapterId] = obj.Viewables.stack(item, string(nansen.internal.getField(params, "adapter", "")));
            plane = double(nansen.internal.getField(params, "plane", 0));
            channel = double(nansen.internal.getField(params, "channel", 0));
            result = nansen.internal.imageFrame(stack, double(nansen.internal.getField(params, "frame", 0)), channel, ...
                string(nansen.internal.getField(params, "projection", "")), double(limits), plane, ...
                string(nansen.internal.getField(params, "filter", "")), nansen.Api.binOf(params));
            result.metadata = nansen.Viewables.metadata(item, stack);
            result.adapter = char(adapterId);
            result.adapters = cellstr(item.adapters);
            result.name = char(item.name);
            if nansen.Api.flag(params, "rois") && item.hasRois
                result.rois = nansen.internal.roiOutlines(nansen.internal.roisAt(item.rois, plane + 1, channel + 1));
            end
        end

        function result = apiViewSignal(obj, params)
            % An ROI's signal read from a registered stack (the mean of its pixels per frame), as rois.signal gives one
            item = obj.Viewables.get(nansen.Api.param(params, "viewable"));
            pixels = nansen.internal.getField(params, "pixels", []);
            if isempty(pixels) || ~(isnumeric(pixels) || iscell(pixels))
                nansen.internal.throwError("invalid-params", "pixels is a list of [row, column] pairs")
            end
            stack = obj.Viewables.stack(item, string(nansen.internal.getField(params, "adapter", "")));
            stack = nansen.internal.pickChannel(stack, double(nansen.internal.getField(params, "channel", 0)), ...
                double(nansen.internal.getField(params, "plane", 0)));
            start = nansen.internal.getField(params, "start", 0);
            stop = nansen.internal.getField(params, "stop", []);
            trace = nansen.internal.roiSignal(stack, pixels, start, stop);
            result = nansen.internal.signalTraces({char(item.name)}, {trace}, 0, start, stop, nansen.internal.getField(params, "maxPoints", 2000));
            result.frameRate = obj.Viewables.rate(item);
        end

        function result = apiViewTraces(obj, params)
            % Columns of registered signals (frames x N), a frame range thinned to maxPoints, as data.traces gives them
            item = obj.Viewables.get(nansen.Api.param(params, "viewable"));
            if item.kind ~= "signals"
                nansen.internal.throwError("invalid-params", "%s is an image stack; view.frame shows it", item.name)
            end
            columns = nansen.internal.getField(params, "columns", 0);
            if ~isnumeric(columns) || any(columns ~= round(columns))
                nansen.internal.throwError("invalid-params", "columns is a list of 0-based column numbers")
            end
            result = nansen.internal.signalTraces({char(item.name)}, {item.signals}, reshape(columns, 1, []), ...
                nansen.internal.getField(params, "start", 0), nansen.internal.getField(params, "stop", []), ...
                nansen.internal.getField(params, "maxPoints", 2000));
            result.frameRate = obj.Viewables.rate(item);
        end

        function result = apiFilesOpen(obj, params)
            % Open a file in its default app, as files.resolve finds it
            result = obj.apiFilesResolve(params);
            if ~result.exists
                nansen.internal.throwError("file-not-found", "%s does not exist", result.path)
            end
            if result.isFolder
                nansen.internal.throwError("invalid-params", "%s is a folder; files.reveal shows folders", result.path)
            end
            obj.OpenFile(string(result.path));
        end

        function result = apiFilesReveal(obj, params)
            result = obj.apiFilesResolve(params);
            if ~result.exists
                nansen.internal.throwError("file-not-found", "%s does not exist", result.path)
            end
            folder = string(result.path);
            if ~result.isFolder
                folder = string(fileparts(folder));
            end
            obj.OpenFolder(folder);
        end

        function result = apiNotesList(obj, params)
            project = obj.requireProject();
            if isfield(params, "entityType")
                types = string(params.entityType);
            elseif isfield(params, "key")
                nansen.internal.throwError("invalid-params", "a key needs its entityType")
            else
                types = project.EntityTypes;
            end
            result = {};
            for type = reshape(types, 1, [])
                notes = project.notebook(type).notes(nansen.internal.getField(params, "key", []));
                for i = 1:numel(notes)
                    notes{i}.entityType = char(type);
                end
                result = [result, notes]; %#ok<AGROW>
            end
            if numel(result) > 1   % newest first; sort is stable, so within a type the order stays
                [~, order] = sort(cellfun(@(n) string(n.createdAt), result), "descend");
                result = result(order);
            end
        end

        function result = apiNotesAdd(obj, params)
            project = obj.requireProject();
            entityType = string(nansen.Api.param(params, "entityType"));
            notebook = project.notebook(entityType);
            author = [];   % absent or null: the user name
            if isfield(params, "author") && ~isnumeric(params.author)
                author = string(params.author);
            end
            result = notebook.add(nansen.Api.param(params, "key"), nansen.internal.getField(params, "text", ''), ...
                Title=nansen.internal.getField(params, "title", ''), Type=nansen.internal.getField(params, "type", 'informal'), ...
                Author=author);
            obj.emit("notes", struct("entityType", char(entityType), "key", result.key));
            result.entityType = char(entityType);
        end

        function result = apiNotesRemove(obj, params)
            project = obj.requireProject();
            entityType = string(nansen.Api.param(params, "entityType"));
            notebook = project.notebook(entityType);
            id = nansen.Api.param(params, "id");
            if ~isnumeric(id) || ~isscalar(id) || id ~= round(id)
                nansen.internal.throwError("invalid-params", "a note's id is an integer")
            end
            notebook.remove(id);
            obj.emit("notes", struct("entityType", char(entityType)));
            result = struct("removed", id);
        end

        function result = apiFragmentsList(obj, ~)
            project = obj.requireProject();
            result = cellfun(@nansen.Api.fragmentSummary, project.fragments(), UniformOutput=false);
            for i = 1:numel(result)
                result{i}.source = 'module';
                if isfile(project.fragmentPath(string(result{i}.id)))
                    result{i}.source = 'project';
                end
            end
        end

        function result = apiFragmentsSave(obj, params)
            % Change a project fragment's definition (not its columns' names, types or order)
            project = obj.requireProject();
            fragment = project.saveFragment(nansen.Api.param(params, "document"));
            users = {};
            for entry = project.Document.entityTypes
                if ismember(fragment.Id, string(nansen.internal.asCellstr(nansen.internal.getField(entry{1}, "fragments", {}))))
                    users{end + 1} = char(string(entry{1}.name)); %#ok<AGROW>
                end
            end
            obj.emit("entities", struct("entityTypes", {users}));
            result = nansen.Api.fragmentSummary(fragment);
        end

        function result = apiFragmentsCreate(obj, params)
            % Save a project fragment (the document); with entityType, also add it to that entity type
            project = obj.requireProject();
            document = nansen.checkDocument(nansen.Api.param(params, "document"), ExpectedType="nansen.fragment");
            entityType = string(nansen.internal.getField(params, "entityType", ""));
            if entityType ~= ""
                names = string(cellfun(@(c) c.name, nansen.internal.asCellOfStructs(document.columns), UniformOutput=false));
                clash = sort(intersect(project.table(entityType).columnNames(), names));
                if ~isempty(clash)   % checked before anything is written
                    nansen.internal.throwError("column-exists", "%s already has column(s) %s", entityType, strjoin(clash, ", "))
                end
            end
            if any(cellfun(@(f) f.Id == string(document.id), project.fragments()))
                nansen.internal.throwError("fragment-exists", "the project already has a fragment '%s'", document.id)
            end
            project.addFragment(document);
            if entityType ~= ""
                project.attachFragment(entityType, document.id);
                obj.emit("entities", struct("entityTypes", {{char(entityType)}}));
            end
            result = nansen.Api.fragmentSummary(project.fragment(string(document.id)));
        end

        function result = apiFragmentsDetach(obj, params)
            project = obj.requireProject();
            entityType = string(nansen.Api.param(params, "entityType"));
            project.detachFragment(entityType, string(nansen.Api.param(params, "fragmentId")));
            obj.emit("entities", struct("entityTypes", {{char(entityType)}}));
            entry = project.entityType(entityType);
            result = struct("entityType", char(entityType), ...
                "fragments", {nansen.internal.asCellstr(nansen.internal.getField(entry, "fragments", {}))});
        end

        function result = apiColumnsReset(obj, params)
            project = obj.requireProject();
            entityType = string(nansen.Api.param(params, "entityType"));
            column = string(nansen.Api.param(params, "column"));
            if isfield(params, "keys")
                count = project.resetColumn(entityType, column, nansen.internal.asCellOfStructs(params.keys));
            else
                count = project.resetColumn(entityType, column);
            end
            obj.emit("entities", struct("entityTypes", {{char(entityType)}}));
            result = struct("reset", count);
        end

        function result = apiFragmentsAttach(obj, params)
            project = obj.requireProject();
            entityType = string(nansen.Api.param(params, "entityType"));
            project.attachFragment(entityType, string(nansen.Api.param(params, "fragmentId")));
            obj.emit("entities", struct("entityTypes", {{char(entityType)}}));
            entry = project.entityType(entityType);
            result = struct("entityType", char(entityType), "fragments", {nansen.internal.asCellstr(entry.fragments)});
        end

        function result = apiFragmentsUpdate(obj, params)
            project = obj.requireProject();
            keys = nansen.internal.asCellOfStructs(nansen.internal.getField(params, "keys", []));
            result = project.updateFragment(string(nansen.Api.param(params, "entityType")), ...
                string(nansen.Api.param(params, "fragmentId")), Keys=keys);
            obj.emit("entities", struct("entityTypes", {{char(params.entityType)}}));
        end

        function result = apiDataVariablesList(obj, params)
            project = obj.requireProject();
            variables = project.dataVariables(string(nansen.internal.getField(params, "entityType", "")));
            result = arrayfun(@(v) v.Document, variables, UniformOutput=false);
        end

        function result = apiDataVariablesOptions(obj, params)
            %apiDataVariablesOptions The locations (with the entity type's file patterns in each) and the file adapters
            project = obj.requireProject();
            entityType = string(nansen.Api.param(params, "entityType"));
            project.entityType(entityType);
            config = project.requireDataset().Config;
            locations = {};
            for location = config.locations()
                id = string(location{1}.identifier);
                locations{end + 1} = struct("id", char(id), ...
                    "title", char(nansen.internal.getField(location{1}, "displayName", id)), ...
                    "access", char(nansen.internal.getField(location{1}, "access", "read")), ...
                    "filePatterns", {keys(project.filePatterns(id, entityType))}); %#ok<AGROW>
            end
            result = struct("locations", {locations}, "fileAdapters", {cellstr(project.adapters().ids())});
        end

        function result = apiAdaptersCreate(obj, params)
            % Start a project file adapter from the templates: its document, and a class to fill in per language
            project = obj.requireProject();
            languages = string(nansen.internal.asCellstr(nansen.internal.getField(params, "languages", {'python', 'matlab'})));
            extensions = string(nansen.internal.asCellstr(nansen.internal.getField(params, "extensions", {})));
            result = project.createAdapter(string(nansen.Api.param(params, "id")), ...
                Title=string(nansen.internal.getField(params, "title", "")), Extensions=reshape(extensions, 1, []), Languages=languages);
            obj.emit("project", struct("name", char(project.Name)));
        end

        function result = apiDataVariablesSave(obj, params)
            project = obj.requireProject();
            variable = project.addDataVariable(nansen.Api.param(params, "document"));
            obj.emit("project", struct("name", char(project.Name)));
            result = variable.Document;
        end

        function result = apiDataVariablesDelete(obj, params)
            project = obj.requireProject();
            name = string(nansen.Api.param(params, "name"));
            project.deleteDataVariable(name);
            obj.emit("project", struct("name", char(project.Name)));
            result = struct("removed", char(name));
        end

        function result = apiAppPlugins(obj, ~)
            % The dashboard scripts of the project's modules ({} with no project open)
            result = {};
            if isempty(obj.Project)
                return
            end
            for module = obj.Project.modules()
                for relative = reshape(string(nansen.internal.asCellstr(nansen.internal.getField(module.Document, "dashboard", {}))), 1, [])
                    result{end + 1} = struct("module", char(module.Id), "path", char(relative), ...
                        "code", nansen.internal.readText(fullfile(module.Folder, relative))); %#ok<AGROW>
                end
            end
        end

        function result = apiModulesResource(obj, params)
            % A text file in the folder of one of the project's modules, such as a dashboard page's data
            project = obj.requireProject();
            id = string(nansen.Api.param(params, "module"));
            found = [];
            for module = project.modules()
                if module.Id == id
                    found = module;
                end
            end
            if isempty(found)
                nansen.internal.throwError("unknown-module", "the project does not use a module '%s'", id)
            end
            relative = string(nansen.Api.param(params, "path"));
            parts = split(replace(relative, "\", "/"), "/");
            if startsWith(relative, ["/", "\"]) || contains(relative, ":") || any(parts == "..")
                nansen.internal.throwError("invalid-params", "'%s' is not a path inside the module", relative)
            end
            path = fullfile(found.Folder, parts{:});
            if ~isfile(path)
                nansen.internal.throwError("file-not-found", "module %s has no %s", found.Id, relative)
            end
            result = struct("module", char(found.Id), "path", char(relative), "text", nansen.internal.readText(path));
        end

        function result = apiModulesData(obj, params)
            % A module's data in the project, as JSON text ("null" when there is none), and its revision (0 then)
            [path, module, name] = obj.moduleDataPath(params);
            if ~isfile(path)
                result = struct("module", module, "name", name, "text", 'null', "revision", 0);
                return
            end
            document = nansen.readDocument(path, ExpectedType="nansen.moduleData");
            result = struct("module", char(document.module), "name", char(document.name), ...
                "text", char(document.text), "revision", document.revision);
        end

        function result = apiModulesSaveData(obj, params)
            % Save a module's data (JSON text); with revision, only when that is still the stored one
            [path, module, name] = obj.moduleDataPath(params);
            current = 0;
            if isfile(path)
                current = nansen.readDocument(path, ExpectedType="nansen.moduleData").revision;
            end
            revision = nansen.internal.getField(params, "revision", []);
            if ~isempty(revision) && revision ~= current
                nansen.internal.throwError("revision-conflict", "%s/%s is at revision %d, not %d", module, name, current, revision)
            end
            text = nansen.internal.getField(params, "text", []);
            try
                jsondecode(char(text));
                valid = ischar(text) || (isstring(text) && isscalar(text));
            catch
                valid = false;
            end
            if ~valid
                nansen.internal.throwError("invalid-params", "text is not JSON text")
            end
            document = struct("schemaType", "nansen.moduleData", "schemaVersion", "0.1.0", "module", module, ...
                "name", name, "revision", current + 1, "text", char(text));
            nansen.checkDocument(document, ExpectedType="nansen.moduleData");
            folder = fileparts(path);
            if ~isfolder(folder)
                mkdir(folder);
            end
            nansen.internal.writeJson(path, document);
            obj.emit("moduleData", struct("module", module, "name", name, "revision", current + 1));
            result = struct("module", module, "name", name, "revision", current + 1);
        end

        function result = apiModulesList(obj, ~)
            %apiModulesList The modules that can be listed (in the project's modules/ folder or built in), and whether they are
            project = obj.requireProject();
            listed = strings(1, 0);
            for entry = nansen.internal.asCellOfStructs(nansen.internal.getField(project.Document, "modules", []))
                listed(end + 1) = string(entry{1}.id); %#ok<AGROW>
            end
            modules = nansen.Module.available(project.Folder);
            ids = string(cellfun(@(m) char(m.Id), modules, UniformOutput=false));
            for module = project.modules()   % a listed module at its own path (a row of nansen.Module)
                if ~ismember(module.Id, ids)
                    modules{end + 1} = module; %#ok<AGROW>
                    ids(end + 1) = module.Id; %#ok<AGROW>
                end
            end
            result = cell(1, numel(modules));
            for i = 1:numel(modules)
                summary = modules{i}.summary();
                summary.listed = ismember(modules{i}.Id, listed);
                result{i} = summary;
            end
        end

        function result = apiModulesAdd(obj, params)
            project = obj.requireProject();
            project.addModule(string(nansen.Api.param(params, "id")), string(nansen.internal.getField(params, "path", "")));
            result = obj.reopen(project);
        end

        function result = apiModulesRemove(obj, params)
            project = obj.requireProject();
            project.removeModule(string(nansen.Api.param(params, "id")));
            result = obj.reopen(project);
        end

        function result = reopen(obj, project)
            % Open the project again after a change to what it lists, and say so
            obj.setProject(nansen.Project.open(project.Folder, Environment=project.Environment));
            obj.emit("project", struct("name", char(obj.Project.Name)));
            result = obj.apiProjectInfo(struct());
        end

        function result = apiDataStatus(obj, params)
            result = obj.requireProject().dataStatus(obj.entity(params));
        end

        function result = apiMethodsList(obj, params)
            project = obj.requireProject();
            methods = project.entityMethods(string(nansen.internal.getField(params, "entityType", "")));
            result = nansen.Api.markedHidden(project, methods);
        end

        function result = apiMethodsSetHidden(obj, params)
            % Leave a method out of the run menus or put it back (dev's Customize Menus); returns methods.list
            hidden = nansen.internal.getField(params, "hidden", true);
            if ~(islogical(hidden) && isscalar(hidden))
                nansen.internal.throwError("invalid-params", "hidden is true or false")
            end
            obj.requireProject().setMethodHidden(string(nansen.Api.param(params, "methodId")), hidden);
            result = obj.apiMethodsList(struct());
        end

        function result = apiMethodsEdit(obj, params)
            % Open a method's code in an editor: in this language unless asked for the other
            method = obj.requireProject().method(string(nansen.Api.param(params, "methodId")));
            files = method.sourceFiles();
            language = string(nansen.internal.getField(params, "language", ""));
            if language == ""
                language = "matlab";
                if ~isfield(files, "matlab") && isfield(files, "python")
                    language = "python";
                end
            end
            if ~isfield(files, language)
                nansen.internal.throwError("method-unavailable", "%s has no %s implementation", method.Id, language)
            end
            path = files.(language);
            if ~isfile(path)
                nansen.internal.throwError("file-not-found", "%s does not exist", path)
            end
            obj.EditFile(path);
            result = struct("language", char(language), "path", char(path));
        end

        function result = apiDataFrame(obj, params)
            % A frame (or a projection) of an image variable, scaled to 8 bits, with the ROIs of another variable and
            % the stack's metadata (frameRate, pixelSize, zStep, as its files give them)
            project = obj.requireProject();
            entity = obj.entity(params);
            limits = nansen.internal.getField(params, "limits", []);
            if ~isempty(limits) && (~isnumeric(limits) || numel(limits) ~= 2)
                nansen.internal.throwError("invalid-params", "limits is [low, high]")
            end
            stack = project.openStack(entity, string(nansen.Api.param(params, "variable")));
            result = nansen.internal.imageFrame(stack, ...
                double(nansen.internal.getField(params, "frame", 0)), double(nansen.internal.getField(params, "channel", 0)), ...
                string(nansen.internal.getField(params, "projection", "")), double(limits), ...
                double(nansen.internal.getField(params, "plane", 0)), string(nansen.internal.getField(params, "filter", "")), ...
                nansen.Api.binOf(params));
            result.metadata = nansen.Api.entityMetadata(stack.Metadata, entity);
            rois = string(nansen.internal.getField(params, "rois", ""));
            if rois ~= ""   % those of the plane and channel shown, when they have places; none before the first is saved
                result.rois = nansen.internal.roiOutlines(nansen.internal.roisAt(nansen.Api.roisOf(project, entity, rois, true), ...
                    double(nansen.internal.getField(params, "plane", 0)) + 1, double(nansen.internal.getField(params, "channel", 0)) + 1));
            end
        end

        function result = apiDataValue(obj, params)
            % The value of a JSON data variable of an entity (as ophys.roi_images saves), for a page to show
            project = obj.requireProject();
            variable = project.dataVariable(string(nansen.Api.param(params, "variable")));
            if variable.FileAdapter ~= "json"
                nansen.internal.throwError("invalid-params", "%s is not a JSON variable; data.frame and data.traces read arrays", variable.Name)
            end
            result = struct("value", {project.load(obj.entity(params), variable.Name)});
        end

        function result = apiDataTraces(obj, params)
            % Columns of signal variables (frames x ROIs) of an entity, a frame range thinned to maxPoints
            project = obj.requireProject();
            entity = obj.entity(params);
            names = nansen.internal.getField(params, "variables", {});
            if ischar(names) || isempty(names) || ~(iscell(names) || isstring(names))
                nansen.internal.throwError("invalid-params", "variables is a list of data variable names")
            end
            names = cellstr(string(names));
            columns = nansen.internal.getField(params, "columns", 0);
            if ~isnumeric(columns) || any(columns ~= round(columns))
                nansen.internal.throwError("invalid-params", "columns is a list of 0-based column numbers")
            end
            arrays = cell(1, numel(names));
            for i = 1:numel(names)
                arrays{i} = project.load(entity, string(names{i}));
            end
            result = nansen.internal.signalTraces(names, arrays, reshape(columns, 1, []), nansen.internal.getField(params, "start", 0), ...
                nansen.internal.getField(params, "stop", []), nansen.internal.getField(params, "maxPoints", 2000));
            result.frameRate = nansen.Api.frameRate(params, entity);
            for i = 1:numel(result.traces)   % what each column is, when the data variable says (a time series' columns)
                columnNames = nansen.internal.getField(project.dataVariable(string(names{i})).Document, "columnNames", {});
                if ~isempty(columnNames)
                    result.traces{i}.columnNames = reshape(cellstr(string(columnNames)), 1, []);
                end
            end
            rois = string(nansen.internal.getField(params, "rois", ""));
            if rois ~= ""
                outlines = nansen.internal.roiOutlines(project.load(entity, rois));
                result.rois = cellfun(@(r) struct("id", r.id, "classification", r.classification), outlines, UniformOutput=false);
            end
        end

        function result = apiDataCache(obj, ~)
            % The project's data cache: what load keeps in memory (dev's DataCache)
            result = obj.requireProject().DataCache.stats();
        end

        function result = apiDataClearCache(obj, ~)
            % Empty the project's data cache; the next load of each variable reads its file
            cache = obj.requireProject().DataCache;
            cache.removeAll();
            result = cache.stats();
        end

        function result = apiRoisUpdate(obj, params)
            % Classify, remove and add ROIs in an ROI variable of an entity, and save it
            project = obj.requireProject();
            entity = obj.entity(params);
            variable = string(nansen.Api.param(params, "variable"));
            restore = missing;   % absent, as opposed to an empty list, which restores no ROIs
            if isfield(params, "restore")
                restore = params.restore;
            end
            plane = double(nansen.internal.getField(params, "plane", 0)) + 1;
            channel = double(nansen.internal.getField(params, "channel", 0)) + 1;
            if ~isfile(project.dataVariablePath(variable))   % a new ROI variable, as roimanager's Save Rois as
                document = project.newVariableDocument(entity, variable, struct());
                document.dataType = 'RoiArray';
                project.addDataVariable(document);
            end
            current = nansen.Api.roisOf(project, entity, variable, false);
            imageSize = nansen.internal.getField(params, "imageSize", []);
            if ~isempty(imageSize) && ~isfield(current, "imageSize")
                current.imageSize = double(reshape(imageSize, 1, []));
            end
            mirror = nansen.Api.flag(params, "mirror");
            aligned = {};
            firstId = 1;
            if mirror
                [aligned, firstId] = obj.alignedRois(project, entity, params, current, variable);
            end
            [document, added] = nansen.internal.updateRoisAt(current, plane, channel, ...
                nansen.internal.getField(params, "classify", []), nansen.internal.getField(params, "remove", []), ...
                nansen.internal.getField(params, "add", []), nansen.internal.getField(params, "move", []), ...
                nansen.internal.getField(params, "merge", []), nansen.internal.getField(params, "pixels", []), restore, ...
                nansen.internal.getField(params, "cellType", []), nansen.internal.getField(params, "link", []), firstId);
            if isfield(params, "import") && ~(isnumeric(params.import) && isempty(params.import))   % null is none
                % roimanager's loaded ROIs, or a segmentation's, added to these
                spec = params.import;
                if ~(isstruct(spec) && isscalar(spec))
                    nansen.internal.throwError("invalid-params", "import is {variable} or {path, adapter?}, and a mode")
                end
                [document, imported] = nansen.internal.importRoisAt(document, plane, channel, obj.importedRois(project, entity, spec), ...
                    nansen.internal.getField(spec, "mode", "append"), firstId);
                added = [reshape(added, 1, []), reshape(imported, 1, [])];
            end
            project.save(entity, variable, document);
            result = struct("rois", {nansen.internal.roiOutlines(nansen.internal.roisAt(document, plane, channel))}, "added", {added});
            if mirror   % the same change made to the ROIs of the entities aligned with this one (dev's synchEntries 'Mirror')
                before = nansen.internal.roiOutlines(nansen.internal.roisAt(current, plane, channel));
                after = nansen.internal.roiOutlines(nansen.internal.roisAt(document, plane, channel));
                alignment = current.alignment;
                source = nansen.internal.alignmentEntry(alignment, entity.Key);
                mirrored = cell(1, numel(aligned));
                for i = 1:numel(aligned)
                    entry = aligned{i}.entry;
                    [value, summary] = nansen.internal.mirrorRoisAt(aligned{i}.value, plane, channel, before, after, source, entry, ...
                        reshape(double(alignment.imageSize), 1, []));
                    project.save(aligned{i}.entity, string(entry.variable), value);
                    mirrored{i} = struct("key", aligned{i}.entity.Key, "added", {summary.added}, "changed", {summary.changed}, ...
                        "removed", {summary.removed});
                end
                result.mirrored = mirrored;
            end
        end

        function [aligned, firstId] = alignedRois(~, project, entity, params, current, variable)
            % The entities aligned with this one by the alignment its ROI file has (ophys.alignSessions writes it): each
            % with its alignment entry and ROI file, those gone or with no file left out; and the first id that is free in
            % all of them, for ROIs added. invalid-params when the file has no alignment, or this entity is not in it.
            % As Python's Api._aligned_rois.
            alignment = nansen.internal.getField(current, "alignment", []);
            if isempty(nansen.internal.alignmentEntry(alignment, entity.Key)) || ~isfield(alignment, "imageSize") || numel(alignment.imageSize) ~= 2
                nansen.internal.throwError("invalid-params", "the ROIs of %s were not aligned with other entities' (ophys.align_sessions): " + ...
                    "there is nothing to mirror the change to", variable)
            end
            idsOf = @(document) cellfun(@(roi) double(roi.id), nansen.internal.roiOutlines(document));
            largest = max([idsOf(current), 0]);
            aligned = {};
            for item = nansen.internal.asCellOfStructs(alignment.entities)
                entry = item{1};
                if ~isempty(nansen.internal.alignmentEntry(struct("entities", {{entry}}), entity.Key))
                    continue
                end
                try
                    other = project.entity(string(nansen.Api.param(params, "entityType")), entry.key);
                    value = project.load(other, string(entry.variable), Cached=false);
                catch err
                    if ~ismember(err.identifier, ["nansen:UnknownEntity", "nansen:DataNotFound", "nansen:UnknownDataVariable"])
                        rethrow(err)
                    end
                    continue
                end
                aligned{end + 1} = struct("entity", other, "entry", entry, "value", value); %#ok<AGROW>
                largest = max([largest, idsOf(value)]);
            end
            firstId = largest + 1;
        end

        function value = importedRois(obj, project, entity, spec)
            % The ROIs rois.update imports: another ROI variable of the entity, or a file (as files.resolve takes it)
            % read by a file adapter (the json adapter for a .json file, when none is given)
            variable = nansen.internal.getField(spec, "variable", "");
            if ~isempty(variable) && string(variable) ~= ""
                value = project.load(entity, string(variable));
                return
            end
            path = nansen.internal.getField(spec, "path", "");
            if isempty(path) || string(path) == ""
                nansen.internal.throwError("invalid-params", "import names an ROI variable or a file's path")
            end
            resolved = obj.apiFilesResolve(spec);
            if ~resolved.exists || resolved.isFolder
                nansen.internal.throwError("file-not-found", "%s is not a file", resolved.path)
            end
            [~, name, extension] = fileparts(string(resolved.path));
            adapterId = nansen.internal.getField(spec, "adapter", "");
            if isempty(adapterId) || string(adapterId) == ""
                adapterId = "";
                if lower(extension) == ".json"
                    adapterId = "json";
                end
            end
            if string(adapterId) == ""
                nansen.internal.throwError("invalid-params", "which file adapter reads %s? Give the import's adapter", name + extension)
            end
            value = project.adapters().get(string(adapterId)).read(string(resolved.path));
        end

        function result = apiRoisDetect(obj, params)
            % The pixels of an ROI found around a point of an image variable (a stack's mean projection)
            project = obj.requireProject();
            entity = obj.entity(params);
            point = nansen.internal.getField(params, "point", []);
            if ~isnumeric(point) || numel(point) ~= 2
                nansen.internal.throwError("invalid-params", "point is [row, column]")
            end
            stack = nansen.internal.pickChannel(project.openStack(entity, string(nansen.Api.param(params, "variable"))), ...
                double(nansen.internal.getField(params, "channel", 0)), double(nansen.internal.getField(params, "plane", 0)));
            pixels = nansen.internal.detectRoi(nansen.internal.meanImage(stack), point, double(nansen.internal.getField(params, "radius", 6)));
            result = struct("pixels", {num2cell(pixels, 2)'});
        end

        function result = apiRoisSignal(obj, params)
            % An ROI's signal read from a stack now (the mean of its pixels per frame), as data.traces gives one
            project = obj.requireProject();
            entity = obj.entity(params);
            pixels = nansen.internal.getField(params, "pixels", []);
            if isempty(pixels) || ~(isnumeric(pixels) || iscell(pixels))
                nansen.internal.throwError("invalid-params", "pixels is a list of [row, column] pairs")
            end
            variable = string(nansen.Api.param(params, "variable"));
            stack = nansen.internal.pickChannel(project.openStack(entity, variable), ...
                double(nansen.internal.getField(params, "channel", 0)), double(nansen.internal.getField(params, "plane", 0)));
            start = nansen.internal.getField(params, "start", 0);
            stop = nansen.internal.getField(params, "stop", []);
            trace = nansen.internal.roiSignal(stack, pixels, start, stop);
            result = nansen.internal.signalTraces({char(variable)}, {trace}, 0, start, stop, nansen.internal.getField(params, "maxPoints", 2000));
            result.frameRate = nansen.Api.frameRate(params, entity);
        end

        function result = apiDataSend(obj, params)
            % Load a data variable of an entity and put it in the base workspace
            variable = string(nansen.Api.param(params, "variable"));
            name = string(nansen.internal.getField(params, "name", variable));
            if name == ""
                name = variable;
            end
            if ~isscalar(name) || ~isvarname(name)
                nansen.internal.throwError("invalid-params", "'%s' is not a variable name", strjoin(name, " "))
            end
            project = obj.requireProject();
            value = project.load(obj.entity(params), variable);
            obj.SendToWorkspace(name, value);
            result = struct("name", char(name), "variable", char(variable));
        end

        function result = apiToolsList(obj, ~)
            project = obj.requireProject();
            result = nansen.Api.markedHidden(project, project.tools());
        end

        function result = apiToolsRun(obj, params)
            % Run a project tool now; its result and log
            project = obj.requireProject();
            method = project.method(string(nansen.Api.param(params, "methodId")));
            context = nansen.MethodContext(Project=project, Method=method);
            value = project.runTool(method.Id, Options=obj.optionsOf(params), ...
                Preset=string(nansen.internal.getField(params, "preset", "")), Context=context);
            if isempty(value) && isnumeric(value)
                value = NaN;   % null
            end
            obj.emit("entities", struct("entityTypes", {cellstr(project.EntityTypes)}));
            result = struct("result", {value}, "log", {cellstr(context.Lines)});
        end

        function result = apiMethodsCreate(obj, params)
            % Start a project method from the templates: its document, and a file to fill in per language
            project = obj.requireProject();
            languages = string(nansen.internal.asCellstr(nansen.internal.getField(params, "languages", {'python', 'matlab'})));
            method = project.createMethod(string(nansen.Api.param(params, "id")), ...
                Title=string(nansen.internal.getField(params, "title", "")), ...
                EntityType=string(nansen.internal.getField(params, "entityType", "*")), ...
                Description=string(nansen.internal.getField(params, "description", "")), ...
                BatchMode=string(nansen.internal.getField(params, "batchMode", "serial")), Languages=languages, ...
                Queueable=logical(nansen.internal.getField(params, "queueable", true)), ...
                Computes=nansen.internal.getField(params, "computes", {}));
            obj.emit("project", struct("name", char(project.Name)));
            result = method.summary();
            files = {char("methods/" + method.Id + ".method.nansen.json")};
            for language = method.Languages
                extension = "m";
                if language == "python"
                    extension = "py";
                end
                files{end + 1} = char(language + "/" + method.Id + "." + extension); %#ok<AGROW>
            end
            if ~isempty(nansen.internal.getField(params, "computes", {}))
                files{end + 1} = char("fragments/" + method.Id + ".fragment.nansen.json");
                obj.emit("entities", struct("entityTypes", {{char(method.EntityType)}}));
            end
            result.files = files;
        end

        function result = apiMethodsRun(obj, params)
            % Run a method now and wait for it; with skipCompleted, the entities it already completed on whose
            % outputs are there are left out (skipped)
            project = obj.requireProject();
            method = project.method(string(nansen.Api.param(params, "methodId")));
            params.preset = char(obj.presetOf(params));
            if ~isempty(method.Languages) && ~any(method.Languages == "matlab")
                result = obj.runInWorker(method, params);
                return
            end
            entities = obj.entities(params);
            skipped = {};
            preset = string(nansen.internal.getField(params, "preset", ""));
            if nansen.Api.flag(params, "skipCompleted")
                values = struct();
                if preset ~= ""
                    values = project.preset(method.Id, preset);
                end
                done = project.alreadyDone(method.Id, entities, nansen.internal.mergeStructs(values, obj.optionsOf(params)));
                skipped = cellfun(@(e) e.Key, entities(done), UniformOutput=false);
                entities = entities(~done);
            end
            results = {};
            if ~isempty(entities)
                results = project.run(method.Id, entities, Options=obj.optionsOf(params), Preset=preset);
                obj.emit("entities", struct("entityTypes", {{char(params.entityType)}}));
            end
            result = struct("results", {results}, "skipped", {skipped});
        end

        function result = runInWorker(obj, method, params)
            % Run a method only another language has: queue it for that language, start a worker for it
            % (queue.startWorker) and wait for the task. A task no worker has started within startTimeout
            % seconds is cancelled.
            language = method.Languages(1);
            queue = obj.queue();
            task = queue.submit(method.Id, obj.entities(params), Options=obj.optionsOf(params), ...
                Preset=string(nansen.internal.getField(params, "preset", "")), Language=language, ...
                SkipCompleted=nansen.Api.flag(params, "skipCompleted"));
            obj.apiQueueStartWorker(struct("language", char(language)));
            timeout = double(nansen.internal.getField(params, "startTimeout", 300));
            started = tic;
            while ~any(string(task.status) == ["completed", "failed", "cancelled"])
                if string(task.status) == "queued" && toc(started) > timeout
                    queue.cancel(string(task.id));
                    nansen.internal.throwError("task-failed", "no %s worker took %s within %g s, so it was cancelled; see tasks/worker-%s.log", ...
                        language, method.Id, timeout, language)
                end
                pause(0.2)
                task = queue.get(string(task.id));
            end
            obj.emit("entities", struct("entityTypes", {{char(params.entityType)}}));
            if string(task.status) ~= "completed"
                message = "";
                if isfield(task, "error") && isstruct(task.error) && isfield(task.error, "message")
                    message = ": " + string(task.error.message);
                end
                nansen.internal.throwError("task-failed", "%s %s in a %s worker%s", method.Id, task.status, language, message)
            end
            results = [];
            if isfield(task, "result")
                results = task.result;
            end
            skipped = {};
            if isfield(task, "skipped")
                skipped = nansen.internal.asCellOfStructs(task.skipped);
            end
            if numel(skipped) == numel(nansen.internal.asCellOfStructs(task.entities))
                results = {};   % every entity was left out
            elseif method.BatchMode ~= "serial"
                results = {results};
            end
            result = struct("results", {results}, "skipped", {skipped}, "taskId", task.id, "language", char(language));
        end

        function result = apiMethodsPreview(obj, params)
            % Run a method on the first frames of one entity's stacks, saving nothing; with a column, on that column of the
            % signals it loads, giving its outputs of one column as traces
            result = nansen.internal.previewMethod(obj.requireProject(), string(nansen.Api.param(params, "methodId")), obj.entity(params), ...
                obj.optionsOf(params), string(nansen.internal.getField(params, "preset", "")), double(nansen.internal.getField(params, "frames", 20)), ...
                nansen.internal.getField(params, "column", []), double(nansen.internal.getField(params, "maxPoints", 2000)));
        end

        function result = apiPresetsList(obj, params)
            project = obj.requireProject();
            methodId = string(nansen.Api.param(params, "methodId"));
            result = project.presets(methodId);
            preferred = project.preferredPreset(methodId);
            for i = 1:numel(result)
                if preferred ~= "" && string(result{i}.name) == preferred
                    result{i}.preferred = true;
                end
            end
        end

        function result = apiPresetsSetDefault(obj, params)
            % Make a preset the one the method runs with when a run gives neither a preset nor options (null: its defaults)
            name = nansen.internal.getField(params, "name", "");
            if isempty(name)
                name = "";
            end
            obj.requireProject().setPreferredPreset(string(nansen.Api.param(params, "methodId")), string(name));
            result = obj.apiPresetsList(params);
        end

        function preset = presetOf(obj, params)
            % The run's preset: the one given, or, when neither a preset nor options are, the method's preferred one
            preset = string(nansen.internal.getField(params, "preset", ""));
            options = nansen.internal.getField(params, "options", []);
            if preset == "" && (isempty(options) || (isstruct(options) && isempty(fieldnames(options))))
                preset = obj.requireProject().preferredPreset(string(nansen.Api.param(params, "methodId")));
            end
        end

        function result = apiPresetsSave(obj, params)
            project = obj.requireProject();
            methodId = string(nansen.Api.param(params, "methodId"));
            project.savePreset(methodId, string(nansen.Api.param(params, "name")), obj.optionsOf(params, "values"), ...
                string(nansen.internal.getField(params, "description", "")));
            result = project.presets(methodId);
        end

        function result = apiPresetsDelete(obj, params)
            project = obj.requireProject();
            methodId = string(nansen.Api.param(params, "methodId"));
            project.deletePreset(methodId, string(nansen.Api.param(params, "name")));
            result = project.presets(methodId);
        end

        function result = apiPipelinesList(obj, params)
            project = obj.requireProject();
            result = project.pipelines(string(nansen.internal.getField(params, "entityType", "")));
            for i = 1:numel(result)
                steps = nansen.internal.asCellOfStructs(result{i}.steps);
                for s = 1:numel(steps)
                    if ~isfield(steps{s}, "title")
                        steps{s}.title = char(project.method(string(steps{s}.method)).Title);
                    end
                end
                result{i}.steps = steps;
                result{i}.source = char(project.pipelineSource(string(result{i}.id)));
            end
        end

        function result = apiPipelinesSave(obj, params)
            result = obj.requireProject().savePipeline(nansen.Api.param(params, "document"));
            obj.emit("pipelines", struct("id", result.id));
        end

        function result = apiPipelinesDelete(obj, params)
            pipelineId = string(nansen.Api.param(params, "pipelineId"));
            obj.requireProject().deletePipeline(pipelineId);
            obj.emit("pipelines", struct("id", char(pipelineId)));
            result = struct("removed", char(pipelineId));
        end

        function result = apiPipelinesMarkStep(obj, params)
            % Mark a step (its method) done or not done for entities by hand, as dev's pipeline viewer's checkboxes
            project = obj.requireProject();
            entityType = string(nansen.Api.param(params, "entityType"));
            method = project.method(string(nansen.Api.param(params, "method")));
            keys = {};
            if isfield(params, "keys")
                keys = nansen.internal.asCellOfStructs(params.keys);
            end
            done = nansen.internal.getField(params, "done", []);
            if ~(islogical(done) && isscalar(done)) || isempty(keys)
                nansen.internal.throwError("invalid-params", "markStep takes keys (one or more) and done (true or false)")
            end
            entities = cellfun(@(key) project.entity(entityType, key), keys, UniformOutput=false);
            marks = ["undone", "done"];
            nansen.internal.recordRuns(project.Folder, method.Id, method.Version, reshape(entities, 1, []), "", marks(done + 1));
            obj.emit("entities", struct("entityTypes", {{char(entityType)}}));
            result = struct("marked", numel(entities));
        end

        function result = apiPipelinesAssign(obj, params)
            project = obj.requireProject();
            entityType = string(nansen.Api.param(params, "entityType"));
            keys = [];
            if isfield(params, "keys")
                keys = nansen.internal.asCellOfStructs(params.keys);
            end
            count = project.assignPipeline(entityType, keys, nansen.internal.getField(params, "pipelineId", []));
            obj.emit("entities", struct("entityTypes", {{char(entityType)}}));
            result = struct("assigned", count);
        end

        function result = apiPipelinesQueueNext(obj, params)
            %apiPipelinesQueueNext For each entity with a pipeline, queue the steps not done yet (from the first not done on)
            project = obj.requireProject();
            entityType = string(nansen.Api.param(params, "entityType"));
            progress = project.pipelineProgress(entityType);
            inFlight = strings(1, 0);
            for task = obj.queue().list()
                t = task{1};
                if isfield(t, "pipeline") && ismember(string(t.status), ["queued", "running"])
                    references = nansen.internal.asCellOfStructs(t.entities);
                    inFlight(end + 1) = string(t.pipeline.id) + "|" + nansen.internal.runKeyId(references{1}.key); %#ok<AGROW>
                end
            end
            skip = containers.Map("KeyType", "char", "ValueType", "any");
            byPipeline = containers.Map("KeyType", "char", "ValueType", "any");
            order = strings(1, 0);
            skipped = {};
            manual = {};
            for entity = obj.entities(params)
                id = nansen.internal.runKeyId(entity{1}.Key);
                if ~isKey(progress, id)
                    skipped{end + 1} = entity{1}.Key; %#ok<AGROW>
                    continue
                end
                state = progress(id);
                if state.done == state.total || ismember(string(state.pipeline) + "|" + id, inFlight)
                    skipped{end + 1} = entity{1}.Key; %#ok<AGROW>   % all done, or its steps are queued already
                    continue
                end
                steps = state.steps;
                first = find(~cellfun(@(s) s.done, steps), 1);
                if ~steps{first}.queueable   % a step to run by hand comes next
                    manual{end + 1} = struct("key", entity{1}.Key, "step", first - 1, "method", steps{first}.method, ...
                        "title", steps{first}.title); %#ok<AGROW>
                    continue
                end
                stop = find(~cellfun(@(s) s.queueable, steps(first:end)), 1) + first - 1;
                if isempty(stop)
                    stop = numel(steps) + 1;
                end
                skip(id) = [0:first - 2, stop - 1:numel(steps) - 1];   % 0-based: before the first not done, and from a manual step on
                if ~isKey(byPipeline, state.pipeline)
                    byPipeline(state.pipeline) = {};
                    order(end + 1) = string(state.pipeline); %#ok<AGROW>
                end
                byPipeline(state.pipeline) = [byPipeline(state.pipeline), entity];
            end
            tasks = {};
            for pipelineId = order
                tasks = [tasks, obj.queue().submitPipeline(pipelineId, byPipeline(char(pipelineId)), ...
                    Language=string(nansen.internal.getField(params, "language", "")), Skip=skip)]; %#ok<AGROW>
            end
            result = struct("tasks", {tasks}, "skipped", {skipped}, "manual", {manual});
        end

        function result = apiPipelinesRunNext(obj, params)
            %apiPipelinesRunNext For each entity with a pipeline, run its next step not done now, in the foreground; with step (from 0), that step
            project = obj.requireProject();
            entityType = string(nansen.Api.param(params, "entityType"));
            progress = project.pipelineProgress(entityType);
            pipelines = containers.Map("KeyType", "char", "ValueType", "any");
            for pipeline = project.pipelines(entityType)
                pipelines(char(string(pipeline{1}.id))) = pipeline{1};
            end
            inFlight = strings(1, 0);
            for task = obj.queue().list()
                t = task{1};
                if isfield(t, "pipeline") && ismember(string(t.status), ["queued", "running"])
                    references = nansen.internal.asCellOfStructs(t.entities);
                    inFlight(end + 1) = nansen.internal.runKeyId(references{1}.key); %#ok<AGROW>
                end
            end
            chosen = nansen.internal.getField(params, "step", []);
            if ~isempty(chosen) && ~(isnumeric(chosen) && isscalar(chosen) && chosen == round(chosen) && chosen >= 0)
                nansen.internal.throwError("invalid-params", "step is the index of a step, from 0")
            end
            ran = {};
            skipped = {};
            for entity = obj.entities(params)
                id = nansen.internal.runKeyId(entity{1}.Key);
                if ~isKey(progress, id) || ismember(id, inFlight)
                    skipped{end + 1} = entity{1}.Key; %#ok<AGROW>
                    continue
                end
                state = progress(id);
                if isempty(chosen) && state.done == state.total
                    skipped{end + 1} = entity{1}.Key; %#ok<AGROW>
                    continue
                end
                if ~isempty(chosen) && chosen >= state.total
                    nansen.internal.throwError("invalid-params", "pipeline '%s' has %d steps; step %d is not one", state.pipeline, state.total, chosen)
                end
                if isempty(chosen)
                    first = find(~cellfun(@(s) s.done, state.steps), 1);
                else
                    first = double(chosen) + 1;
                end
                pipeline = pipelines(char(state.pipeline));
                stepList = nansen.internal.asCellOfStructs(pipeline.steps);
                step = stepList{first};
                options = nansen.internal.getField(step, "options", struct());
                if isempty(options)
                    options = struct();
                end
                method = project.method(string(step.method));
                if ~isempty(method.Languages) && ~any(method.Languages == "matlab")   % in a worker of the language it has
                    results = obj.runInWorker(method, struct("methodId", char(method.Id), "entityType", char(entityType), ...
                        "keys", {{entity{1}.Key}}, "options", options, "preset", char(string(nansen.internal.getField(step, "preset", ""))))).results;
                    if ~iscell(results)
                        results = num2cell(results);
                    end
                else
                    results = project.run(string(step.method), entity, Options=options, ...
                        Preset=string(nansen.internal.getField(step, "preset", "")));
                end
                value = NaN;
                if ~isempty(results) && ~isempty(results{1})
                    value = results{1};
                end
                ran{end + 1} = struct("key", entity{1}.Key, "step", first - 1, "method", char(string(step.method)), "result", {value}); %#ok<AGROW>
            end
            if ~isempty(ran)
                obj.emit("entities", struct("entityTypes", {{char(entityType)}}));
            end
            result = struct("ran", {ran}, "skipped", {skipped});
        end

        function result = apiPipelinesSubmit(obj, params)
            result = obj.queue().submitPipeline(string(nansen.Api.param(params, "pipelineId")), obj.entities(params), ...
                Language=string(nansen.internal.getField(params, "language", "")));
        end

        function result = apiTasksSubmit(obj, params)
            result = obj.queue().submit(string(nansen.Api.param(params, "methodId")), obj.entities(params), ...
                Options=obj.optionsOf(params), Preset=obj.presetOf(params), ...
                Language=string(nansen.internal.getField(params, "language", "")), ...
                SkipCompleted=nansen.Api.flag(params, "skipCompleted"));
        end

        function result = apiTasksComment(obj, params)
            comment = nansen.internal.getField(params, "comment", "");
            if isempty(comment)
                comment = "";
            end
            result = obj.queue().comment(string(nansen.Api.param(params, "id")), string(comment));
        end

        function result = apiTasksList(obj, params)
            result = obj.queue().list(string(nansen.internal.getField(params, "status", "")));
        end

        function result = apiTasksGet(obj, params)
            queue = obj.queue();
            id = string(nansen.Api.param(params, "id"));
            result = queue.get(id);
            result.logText = char(queue.log(id));
        end

        function result = apiTasksCancel(obj, params)
            result = obj.queue().cancel(string(nansen.Api.param(params, "id")));
        end

        function result = apiTasksRetry(obj, params)
            % A finished task queued again (dev's Restart); skipCompleted, when given, replaces the task's
            skip = [];
            if isfield(params, "skipCompleted")
                skip = nansen.Api.flag(params, "skipCompleted");
            end
            result = obj.queue().retry(string(nansen.Api.param(params, "id")), SkipCompleted=skip);
        end

        function result = apiTasksHold(obj, params)
            result = obj.queue().hold(string(nansen.Api.param(params, "id")), ...
                logical(nansen.internal.getField(params, "hold", true)));
        end

        function result = apiTasksUpdate(obj, params)
            result = obj.queue().update(string(nansen.Api.param(params, "id")), ...
                Options=obj.optionsOf(params), Preset=string(nansen.internal.getField(params, "preset", "")));
        end

        function result = apiTasksReorder(obj, params)
            ids = nansen.Api.param(params, "ids");
            if isnumeric(ids) && isempty(ids)
                ids = strings(1, 0);   % []
            end
            result = obj.queue().reorder(string(ids));
        end

        function result = apiTasksRemove(obj, params)
            id = string(nansen.Api.param(params, "id"));
            obj.queue().remove(id);
            result = struct("removed", char(id));
        end

        function result = apiTasksClear(obj, ~)
            result = struct("removed", obj.queue().clear());
        end

        function result = apiTasksRunNext(obj, ~)
            result = obj.queue().runNext();
            if isempty(result)
                result = NaN;   % null
            end
        end

        function result = apiQueueStatus(obj, ~)
            queue = obj.queue();
            counts = struct();
            for task = queue.list()
                status = string(task{1}.status);
                counts.(status) = nansen.internal.getField(counts, status, 0) + 1;
            end
            result = struct("running", queue.isRunning(), "executor", 'matlab', "worker", char(queue.Worker), "counts", counts);
        end

        function result = apiQueueStart(obj, ~)
            obj.queue().start();
            result = obj.apiQueueStatus(struct());
        end

        function result = apiQueueStartWorker(obj, params)
            % Start a worker for the tasks of a language: this app's own, or a Python one (python -m nansen worker)
            % for tasks only Python runs, which stops when none is left. Its output goes to tasks/worker-python.log.
            language = string(nansen.internal.getField(params, "language", ""));
            if language == "matlab"
                result = obj.apiQueueStart(params);
                return
            end
            if language ~= "python"
                nansen.internal.throwError("invalid-params", "language is python or matlab")
            end
            project = obj.requireProject();
            executable = "";
            if ~isempty(obj.Catalog)
                executable = string(nansen.internal.getField(obj.Catalog.settings().workers, "python", ""));
            end
            if executable == ""
                try
                    executable = string(pyenv().Executable);
                catch
                    executable = "";
                end
            end
            if executable == ""
                executable = "python3";
                if ispc
                    executable = "python";
                end
            end
            log = fullfile(project.Folder, "tasks", "worker-python.log");
            if ~isfolder(fileparts(log))
                mkdir(fileparts(log));
            end
            command = string(sprintf('"%s" -m nansen worker "%s" --until-empty', executable, project.Folder));
            if project.Environment ~= ""
                command = command + sprintf(' --environment "%s"', project.Environment);
            end
            if ispc
                status = system(sprintf('start "" /B cmd /c "%s >> "%s" 2>&1"', command, log));
            else
                status = system(sprintf('%s >> "%s" 2>&1 &', command, log));
            end
            if status ~= 0
                nansen.internal.throwError("dependency-missing", "could not start %s: set the Python to use in Settings", executable)
            end
            result = struct("language", 'python', "started", true, "log", char(log));
        end

        function result = apiQueueStop(obj, ~)
            obj.queue().stop();
            result = obj.apiQueueStatus(struct());
        end
    end

    methods (Access = private)
        function removeListener(obj, index)
            obj.Listeners{index} = [];
        end

        function setProject(obj, project)
            if ~isempty(obj.Queue)
                obj.Queue.stop();
            end
            obj.Project = project;
            worker = "thread";   % the user's setting (queue.worker) when there is a catalog
            if ~isempty(obj.Catalog)
                worker = string(obj.Catalog.settings().queue.worker);
            end
            obj.Queue = nansen.TaskQueue(project, OnEvent=@(kind, data) obj.emit(kind, data), Worker=worker);
            if ~isempty(obj.Catalog)
                obj.Catalog.add(project);
            end
            if obj.StartQueue
                obj.Queue.start();
            end
        end

        function [path, module, name] = moduleDataPath(obj, params)
            project = obj.requireProject();
            module = char(string(nansen.Api.param(params, "module")));
            name = char(string(nansen.Api.param(params, "name")));
            if ~any(arrayfun(@(m) m.Id == module, project.modules()))
                nansen.internal.throwError("unknown-module", "the project does not use a module '%s'", module)
            end
            if isempty(regexp(name, '^[A-Za-z0-9][A-Za-z0-9_-]*$', "once"))
                nansen.internal.throwError("invalid-params", "'%s' is not a name for module data", name)
            end
            path = fullfile(project.Folder, "module-data", module, name + ".json");
        end

        function addons = declaredAddons(obj)
            if isempty(obj.Project)
                addons = nansen.Addons.declared(nansen.Module.available(""));
            else
                addons = nansen.Addons.declared(obj.Project.modules());
            end
        end

        function folder = addonsFolder(obj)
            settings = obj.apiSettingsGet(struct());
            folder = string(nansen.internal.getField(nansen.internal.getField(settings, "addons", struct()), "folder", ""));
            if folder == ""
                folder = nansen.Addons.defaultFolder();
            end
        end

        function project = requireProject(obj)
            if isempty(obj.Project)
                nansen.internal.throwError("no-project", "no project is open")
            end
            project = obj.Project;
        end

        function queue = queue(obj)
            obj.requireProject();
            queue = obj.Queue;
        end

        function entity = entity(obj, params)
            entity = obj.requireProject().entity(string(nansen.Api.param(params, "entityType")), ...
                nansen.Api.param(params, "key"));
        end

        function chosen = entities(obj, params)
            everything = obj.requireProject().entities(string(nansen.Api.param(params, "entityType")));
            if ~isfield(params, "keys")
                chosen = everything;
                return
            end
            wanted = nansen.internal.asCellOfStructs(params.keys);
            keep = false(1, numel(everything));
            for i = 1:numel(everything)
                for j = 1:numel(wanted)
                    keep(i) = keep(i) || nansen.Api.keyMatches(everything{i}.Key, wanted{j});
                end
            end
            chosen = everything(keep);
            if numel(chosen) ~= numel(wanted)
                nansen.internal.throwError("unknown-entity", "some keys match no entity")
            end
        end

        function options = optionsOf(~, params, field)
            if nargin < 3
                field = "options";
            end
            options = nansen.internal.getField(params, field, struct());
            if isempty(options)
                options = struct();
            end
        end

        function out = row(~, entity, table, jsonRow)
            % jsonRow: the entity's table row as JSON values, when the caller has it already
            values = entity.Key;
            values = nansen.internal.mergeStructs(values, entity.attributes());
            if entity.inTable()
                if nargin < 4
                    jsonRow = table.jsonRow(entity.Row);
                end
                values = nansen.internal.mergeStructs(values, jsonRow);
            end
            out = struct("key", entity.Key, "inStore", entity.inStore(), "inTable", entity.inTable(), "values", values);
            if ~isempty(entity.Issues)
                out.issues = cellstr(entity.issueCodes());
            end
        end

        function columns = columns(obj, entityType, table)
            project = obj.requireProject();
            titles = struct();
            computed = strings(1, 0);
            entry = project.entityType(entityType);
            for fragmentId = string(nansen.internal.asCellstr(nansen.internal.getField(entry, "fragments", {})))
                fragment = project.fragment(fragmentId);
                if isfield(fragment.Document, "compute")
                    computed(end + 1) = fragmentId; %#ok<AGROW>
                end
                for column = nansen.internal.asCellOfStructs(fragment.Document.columns)
                    titles.(column{1}.name) = column{1};
                end
            end
            columns = {};
            for column = table.Columns
                isKey = ismember(column.Name, table.Key);
                info = nansen.internal.getField(titles, column.Name, struct());
                fragment = NaN;
                if column.Fragment ~= ""
                    fragment = char(column.Fragment);
                end
                unit = NaN;
                if column.Unit ~= ""
                    unit = char(column.Unit);
                elseif isfield(info, "unit")
                    unit = info.unit;
                end
                source = 'table';
                if isKey
                    source = 'key';
                end
                entry = struct("name", char(column.Name), "dataType", char(column.DataType), ...
                    "title", char(nansen.internal.getField(info, "title", column.Name)), "unit", unit, ...
                    "fragment", fragment, "source", source, ...
                    "editable", ~isKey && ~ismember(column.Fragment, computed));
                if isfield(info, "choices")
                    entry.choices = nansen.internal.asCellstr(info.choices);
                end
                for hint = ["display", "action"]   % how the dashboard draws the cells, and what a double-click runs
                    if isfield(info, hint)
                        entry.(hint) = info.(hint);
                    end
                end
                if column.Name == "pipeline" && column.Fragment == "core.pipeline"
                    entry.choices = cellfun(@(p) char(string(p.id)), project.pipelines(entityType), UniformOutput=false);
                end
                columns{end + 1} = entry; %#ok<AGROW>
            end
            dataset = project.dataset();
            if ~isempty(dataset) && ismember(entityType, dataset.entityTypes())
                definitions = dataset.Config.definitions();
                seen = string(cellfun(@(c) c.name, columns, UniformOutput=false));
                for name = reshape(string(fieldnames(definitions)), 1, [])
                    definition = definitions.(name);
                    if string(definition.ofEntity) == entityType && ~ismember(name, seen)
                        columns{end + 1} = struct("name", char(name), "dataType", char(definition.dataType), ...
                            "title", char(nansen.internal.getField(definition, "title", name)), ...
                            "unit", nansen.internal.getField(definition, "unit", NaN), "fragment", NaN, ...
                            "source", 'attribute', "editable", false); %#ok<AGROW>
                    end
                end
            end
        end
    end

    methods (Static)
        function entries = unmatchedOf(scan)
            % The scan's unmatched entries, without those it skipped on purpose (reason excluded)
            entries = scan.Unmatched;
            if isempty(entries)
                return
            end
            entries = entries(cellfun(@(u) string(nansen.internal.getField(u, "reason", "")) ~= "excluded", entries));
        end

        function openInEditor(path)
            edit(char(path));
        end

        function assignInBase(name, value)
            assignin("base", name, value);
        end

        function openInFileBrowser(folder)
            %openInFileBrowser Show a folder in Finder, Explorer or the desktop's file manager
            if ispc
                winopen(folder);
            elseif ismac
                status = system(sprintf('open "%s"', folder));
            else
                status = system(sprintf('xdg-open "%s" > /dev/null 2>&1 &', folder));
            end
            if ~ispc && status ~= 0
                nansen.internal.throwError("cannot-open", "could not open %s", folder)
            end
        end
    end

    methods (Static, Access = private)
        function result = markedHidden(project, found)
            % Method summaries, those left out of the run menus with hidden: true
            hidden = project.hiddenMethods();
            result = cell(1, numel(found));
            for i = 1:numel(found)
                result{i} = found(i).summary();
                if ismember(string(found(i).Id), hidden)
                    result{i}.hidden = true;
                end
            end
        end

        function [value, state] = progressOf(progress, key)
            % The fraction of the entity's pipeline that is done, or [] (null) when it has none
            value = [];
            state = [];
            id = nansen.internal.runKeyId(key);
            if isKey(progress, id)
                state = progress(id);
                value = state.done / state.total;
            end
        end

        function rate = frameRate(params, entity)
            % data.traces' frames per second: the frameRate given, else the entity's frame_rate when it is a positive number; [] (null) when neither
            given = nansen.internal.getField(params, "frameRate", []);
            if ~isempty(given)
                if ~(isnumeric(given) && isscalar(given) && isfinite(given) && given > 0)
                    nansen.internal.throwError("invalid-params", "frameRate is a positive number of frames per second")
                end
                rate = double(given);
                return
            end
            rate = entity.get("frame_rate", []);
            if ~(isnumeric(rate) && isscalar(rate) && isfinite(rate) && rate > 0)
                rate = [];
            else
                rate = double(rate);
            end
        end
    end

    methods (Access = private)
        function tf = hasPipelines(~, project, entityType)
            listed = string(nansen.internal.asCellstr(nansen.internal.getField(project.entityType(entityType), "fragments", {})));
            tf = ismember("core.pipeline", listed);
        end
    end

    methods (Static, Access = private)
        function value = nullIfEmpty(text)
            % No environment is null in the protocol, as in Python
            value = [];
            if ~(isempty(text) || (isstring(text) && (ismissing(text) || text == "")))
                value = char(text);
            end
        end

        function summary = fragmentSummary(f)
            summary = struct("id", char(f.Id), "version", char(f.Version), ...
                "title", char(nansen.internal.getField(f.Document, "title", f.Id)), ...
                "description", char(nansen.internal.getField(f.Document, "description", "")), ...
                "computed", isfield(f.Document, "compute"), ...
                "columns", {nansen.internal.asCellOfStructs(f.Document.columns)});
        end

        function configure(project, params)
            source = string(nansen.internal.getField(params, "datasetSource", ""));
            text = string(nansen.internal.getField(params, "datasetText", ""));
            if source ~= ""
                project.setDataset(source);
            elseif text ~= ""
                project.setDatasetText(text);
            end
            for module = string(nansen.internal.asCellstr(nansen.internal.getField(params, "modules", {})))
                project.addModule(module);
            end
            addTypes = nansen.internal.getField(params, "entityTypes", false);
            if islogical(addTypes) && isscalar(addTypes) && addTypes
                modules = strings(1, 0);
                for module = nansen.internal.asCellOfStructs(nansen.internal.getField(project.Document, "modules", []))
                    modules(end + 1) = string(module{1}.id); %#ok<AGROW>
                end
                fragments = string.empty(1, 0);
                if ismember("core", modules)
                    fragments = "core.notes";
                end
                added = project.addDatasetEntityTypes(Fragments=fragments);
                if ismember("core", modules) && ismember("subject", added)   % as dev's subject table: date of birth, sex, species
                    project.attachFragment("subject", "core.subject");
                end
            end
        end

        function metadata = entityMetadata(metadata, entity)
            % A stack's metadata, with what its files do not give taken from the entity's columns (dev's Edit Stack
            % Properties): frameRate from frame_rate, pixelSize from pixel_size_um, zStep from z_step_um; as Python's
            keys = ["frameRate", "pixelSize", "zStep"];
            columns = ["frame_rate", "pixel_size_um", "z_step_um"];
            for i = 1:3
                value = entity.get(columns(i), []);
                if ~isfield(metadata, keys(i)) && isnumeric(value) && isscalar(value) && isfinite(value) && value > 0
                    value = floor(double(value) * 1e6 + 0.5) / 1e6;
                    if keys(i) == "pixelSize"
                        value = [value, value];
                    end
                    metadata.(keys(i)) = value;
                end
            end
        end

        function value = binOf(params)
            % data.frame's bin: struct size (2 or more frames), method (mean or max), or []
            value = [];
            if ~isfield(params, "bin") || isempty(params.bin)
                return
            end
            size_ = nansen.internal.getField(params.bin, "size", []);
            method = string(nansen.internal.getField(params.bin, "method", "mean"));
            if ~(isnumeric(size_) && isscalar(size_) && size_ == round(size_) && size_ >= 2) || ~ismember(method, ["mean", "max"])
                nansen.internal.throwError("invalid-params", "bin is {size: 2 or more frames, method: mean or max}")
            end
            value = struct("size", double(size_), "method", method);
        end

        function value = roisOf(project, entity, name, cached)
            % An ROI variable's value, or no ROIs when the entity has no file of it yet (or the project no such variable)
            try
                value = project.load(entity, name, Cached=cached);
            catch err
                if ~ismember(err.identifier, ["nansen:DataNotFound", "nansen:UnknownDataVariable"])
                    rethrow(err)
                end
                value = struct("rois", {{}});
            end
        end

        function value = flag(params, name)
            % A true-or-false parameter, false when not given
            value = nansen.internal.getField(params, name, false);
            if ~(islogical(value) && isscalar(value))
                nansen.internal.throwError("invalid-params", "%s is true or false", name)
            end
        end

        function value = param(params, name)
            if ~isfield(params, name)
                error("nansen:Api:MissingParameter", "missing parameter '%s'", name)
            end
            value = params.(name);
        end

        function tf = keyMatches(key, wanted)
            tf = true;
            for name = reshape(string(fieldnames(wanted)), 1, [])
                tf = tf && isfield(key, name) && isequal(string(key.(name)), string(wanted.(name)));
            end
        end
    end
end
