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
    end

    properties
        % Opens a folder in the system's file browser; tests put their own here
        OpenFolder function_handle = @nansen.Api.openInFileBrowser
        SendToWorkspace function_handle = @nansen.Api.assignInBase   % (name, value): where workspace.send puts entities
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
            end
            obj.Catalog = options.Catalog;
            obj.Methods = containers.Map("KeyType", "char", "ValueType", "any");
            names = ["app.info", "workspace.send", "catalog.list", "catalog.remove", "project.open", "project.create", "project.info", ...
                "project.setDataset", "dataset.setRoot", "dataset.get", "dataset.save", "demo.create", "legacy.import", ...
                "project.scan", "project.sync", "entities.list", "entities.get", "entities.update", "entities.add", ...
                "entities.remove", "columns.reset", "fragments.detach", "notes.list", "notes.add", "notes.remove", "files.resolve", "files.list", "files.reveal", "views.list", "views.save", "views.delete", "fragments.list", "fragments.create", "fragments.attach", "fragments.update", "dataVariables.list", "dataVariables.options", "dataVariables.save", "dataVariables.delete", "data.status", "modules.list", "modules.add", "modules.remove", ...
                "methods.list", "methods.create", "tools.list", "tools.run", "methods.run", "presets.list", "presets.save", "presets.delete", ...
                "pipelines.list", "pipelines.submit", "pipelines.save", "pipelines.delete", "pipelines.assign", "pipelines.queueNext", "tasks.submit", "tasks.list", "tasks.get", "tasks.cancel", "tasks.retry", "tasks.remove", "tasks.hold", "tasks.update", "tasks.reorder", ...
                "tasks.clear", "tasks.runNext", "queue.status", "queue.start", "queue.stop"];
            for name = names
                % "entities.list" -> apiEntitiesList
                handler = "api" + join(arrayfun(@(p) upper(extractBefore(p, 2)) + extractAfter(p, 1), split(name, ".")'), "");
                obj.Methods(char(name)) = char(handler);
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

        function result = apiCatalogRemove(obj, params)
            if isempty(obj.Catalog)
                nansen.internal.throwError("no-catalog", "this app has no project catalog")
            end
            obj.Catalog.remove(nansen.Api.param(params, "path"));
            result = obj.Catalog.projects();
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
            obj.setProject(nansen.demo.create(nansen.Api.param(params, "path")));
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
                "unmatched", numel(scan.Unmatched));
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
            result = obj.row(project.entity(entityType, key), project.table(entityType));
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
            result = arrayfun(@(m) m.summary(), methods, UniformOutput=false);
        end

        function result = apiToolsList(obj, ~)
            result = arrayfun(@(m) m.summary(), obj.requireProject().tools(), UniformOutput=false);
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
                BatchMode=string(nansen.internal.getField(params, "batchMode", "serial")), Languages=languages);
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
            result.files = files;
        end

        function result = apiMethodsRun(obj, params)
            project = obj.requireProject();
            results = project.run(string(nansen.Api.param(params, "methodId")), obj.entities(params), ...
                Options=obj.optionsOf(params), Preset=string(nansen.internal.getField(params, "preset", "")));
            obj.emit("entities", struct("entityTypes", {{char(params.entityType)}}));
            result = struct("results", {results});
        end

        function result = apiPresetsList(obj, params)
            result = obj.requireProject().presets(string(nansen.Api.param(params, "methodId")));
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
                first = find(~cellfun(@(s) s.done, state.steps), 1);
                skip(id) = 0:first - 2;
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
            result = struct("tasks", {tasks}, "skipped", {skipped});
        end

        function result = apiPipelinesSubmit(obj, params)
            result = obj.queue().submitPipeline(string(nansen.Api.param(params, "pipelineId")), obj.entities(params), ...
                Language=string(nansen.internal.getField(params, "language", "")));
        end

        function result = apiTasksSubmit(obj, params)
            result = obj.queue().submit(string(nansen.Api.param(params, "methodId")), obj.entities(params), ...
                Options=obj.optionsOf(params), Preset=string(nansen.internal.getField(params, "preset", "")), ...
                Language=string(nansen.internal.getField(params, "language", "")));
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
            result = obj.queue().retry(string(nansen.Api.param(params, "id")));
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
            result = struct("running", queue.isRunning(), "executor", 'matlab', "counts", counts);
        end

        function result = apiQueueStart(obj, ~)
            obj.queue().start();
            result = obj.apiQueueStatus(struct());
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
            obj.Queue = nansen.TaskQueue(project, OnEvent=@(kind, data) obj.emit(kind, data));
            if ~isempty(obj.Catalog)
                obj.Catalog.add(project);
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
            if source ~= ""
                project.setDataset(source);
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
