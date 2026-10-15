classdef Method
%Method A nansen.method declaration, with the folder its MATLAB code is in
%
%   A serial method is called once per entity as f(entity, options,
%   context); a batch method once as f(entities, options, context), with
%   entities a cell array.

    properties (SetAccess = private)
        Document (1,1) struct
        MatlabRoot (1,1) string = ""
        Module (1,1) string = ""
    end

    properties (Dependent)
        Id
        Version
        Title
        EntityType
        BatchMode
        Queueable
        Languages
    end

    methods
        function obj = Method(document, matlabRoot, module)
            arguments
                document (1,1) struct
                matlabRoot (1,1) string = ""
                module (1,1) string = ""
            end
            obj.Document = document;
            obj.MatlabRoot = matlabRoot;
            obj.Module = module;
        end

        function value = get.Id(obj)
            value = string(obj.Document.id);
        end

        function value = get.Version(obj)
            value = string(obj.Document.version);
        end

        function value = get.Title(obj)
            value = string(nansen.internal.getField(obj.Document, "title", obj.Document.id));
        end

        function value = get.EntityType(obj)
            value = string(obj.Document.entityType);
        end

        function value = get.BatchMode(obj)
            value = string(nansen.internal.getField(obj.Document, "batchMode", "serial"));
        end

        function value = get.Queueable(obj)
            value = logical(nansen.internal.getField(obj.Document, "queueable", true));
        end

        function value = get.Languages(obj)
            value = reshape(sort(string(fieldnames(obj.Document.implementations))), 1, []);
        end

        function tf = appliesTo(obj, entityType)
            tf = ~obj.isTool() && (obj.EntityType == "*" || obj.EntityType == string(entityType));
        end

        function tf = isTool(obj)
            %isTool A project tool (entityType @project) runs once on the project, not on entities
            tf = obj.EntityType == "@project";
        end

        function schema = optionsSchema(obj)
            schema = nansen.internal.getField(obj.Document, "options", struct("type", 'object', "properties", struct()));
        end

        function options = defaultOptions(obj)
            options = nansen.internal.defaultsOf(obj.optionsSchema());
            if isempty(options)
                options = struct();
            end
        end

        function options = resolveOptions(obj, values)
            %resolveOptions The defaults overlaid with the given values (a struct), validated against the options schema
            arguments
                obj
                values = struct()
            end
            if isempty(values)
                values = struct();
            end
            options = nansen.internal.mergeStructs(obj.defaultOptions(), values);
            errors = nansen.internal.schemaValidationErrors(nansen.internal.jsonRoundTrip(options), obj.optionsSchema());
            if ~isempty(errors)
                nansen.internal.throwError("invalid-options", "%s: %s", obj.Id, strjoin(errors, "; "))
            end
        end

        function files = sourceFiles(obj)
            %sourceFiles Where each language's implementation is: a struct of language -> file (which may not exist)
            files = struct();
            implementations = obj.Document.implementations;
            if obj.MatlabRoot == ""
                return
            end
            if isfield(implementations, "matlab")
                parts = split(string(implementations.matlab), ".")';
                folders = "+" + parts(1:end-1);
                files.matlab = string(fullfile(obj.MatlabRoot, folders{:}, parts(end) + ".m"));
            end
            if isfield(implementations, "python")
                pythonRoot = fullfile(fileparts(obj.MatlabRoot), "python");   % the module's (or project's) python/ beside matlab/
                parts = split(extractBefore(string(implementations.python), ":"), ".")';
                base = fullfile(pythonRoot, parts{:});
                if isfolder(base)
                    files.python = string(fullfile(base, "__init__.py"));
                else
                    files.python = string(base + ".py");
                end
            end
        end

        function handle = functionHandle(obj)
            %functionHandle The MATLAB implementation; the module's matlab/ folder is put on the path
            if ~isfield(obj.Document.implementations, "matlab")
                nansen.internal.throwError("method-unavailable", "method '%s' has no MATLAB implementation", obj.Id)
            end
            if obj.MatlabRoot ~= "" && isfolder(obj.MatlabRoot) && ~contains(path, obj.MatlabRoot)
                addpath(obj.MatlabRoot);
            end
            name = string(obj.Document.implementations.matlab);
            if ~exist(name, "file")
                nansen.internal.throwError("method-unavailable", "function %s is not on the path", name)
            end
            handle = str2func(name);
        end

        function summary = summary(obj)
            summary = struct("id", char(obj.Id), "version", char(obj.Version), "title", char(obj.Title), ...
                "entityType", char(obj.EntityType), ...
                "description", char(nansen.internal.getField(obj.Document, "description", "")), ...
                "category", char(nansen.internal.getField(obj.Document, "category", "")), ...
                "batchMode", char(obj.BatchMode), "queueable", obj.Queueable, ...
                "languages", {cellstr(obj.Languages)}, "module", char(obj.Module), "options", obj.optionsSchema(), "tool", obj.isTool());
        end
    end
end
