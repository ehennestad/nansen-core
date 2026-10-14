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
            names = ["app.info", "catalog.list", "catalog.remove", "project.open", "project.create", "project.info", ...
                "project.setDataset", "demo.create", "legacy.import", ...
                "project.scan", "project.sync", "entities.list", "entities.get", "entities.update", "entities.add", ...
                "entities.remove", "fragments.list", "fragments.create", "fragments.attach", "fragments.update", "dataVariables.list", "data.status", ...
                "methods.list", "methods.run", "presets.list", "presets.save", "presets.delete", ...
                "pipelines.list", "pipelines.submit", "tasks.submit", "tasks.list", "tasks.get", "tasks.cancel", "tasks.retry", "tasks.remove", ...
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
                "protocolVersion", char(nansen.Api.ProtocolVersion), "methods", {cellstr(obj.methodNames())});
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
            if source ~= "" && ~isfile(source)
                nansen.internal.throwError("file-not-found", "no DSM config %s", source)
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
                    "path", char(r.Path), "environment", char(r.Environment), "available", r.Available), dataset.roots(), ...
                    UniformOutput=false);
                result.dataset = struct("environment", char(dataset.Environment), ...
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
            rows = cellfun(@(e) obj.row(e, table), entities, UniformOutput=false);
            result = struct("entityType", char(entityType), "key", {cellstr(table.Key)}, ...
                "columns", {obj.columns(entityType, table)}, "rows", {rows});
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

        function result = apiDataStatus(obj, params)
            result = obj.requireProject().dataStatus(obj.entity(params));
        end

        function result = apiMethodsList(obj, params)
            project = obj.requireProject();
            methods = project.entityMethods(string(nansen.internal.getField(params, "entityType", "")));
            result = arrayfun(@(m) m.summary(), methods, UniformOutput=false);
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
            end
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

        function out = row(~, entity, table)
            values = entity.Key;
            values = nansen.internal.mergeStructs(values, entity.attributes());
            if entity.inTable()
                values = nansen.internal.mergeStructs(values, table.jsonRow(entity.Row));
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
                columns{end + 1} = struct("name", char(column.Name), "dataType", char(column.DataType), ...
                    "title", char(nansen.internal.getField(info, "title", column.Name)), "unit", unit, ...
                    "fragment", fragment, "source", source, ...
                    "editable", ~isKey && ~ismember(column.Fragment, computed)); %#ok<AGROW>
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

    methods (Static, Access = private)
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
                project.addDatasetEntityTypes(Fragments=fragments);
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
