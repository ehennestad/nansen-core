classdef Module
%Module A module folder: fragments, methods and file adapters listed in module.nansen.json
%
%   Its MATLAB code is in matlab/ and its Python code in python/.

    properties (SetAccess = private)
        Folder (1,1) string
        Document (1,1) struct
    end

    properties (Dependent)
        Id
        Version
        MatlabRoot
    end

    methods
        function obj = Module(folder, document)
            arguments
                folder (1,1) string
                document (1,1) struct
            end
            obj.Folder = folder;
            obj.Document = document;
        end

        function id = get.Id(obj)
            id = string(obj.Document.id);
        end

        function version = get.Version(obj)
            version = string(obj.Document.version);
        end

        function root = get.MatlabRoot(obj)
            root = string(fullfile(obj.Folder, "matlab"));
        end

        function documents = fragmentDocuments(obj)
            documents = obj.documents("fragments", "nansen.fragment");
        end

        function documents = fileAdapterDocuments(obj)
            documents = obj.documents("fileAdapters", "nansen.fileAdapter");
        end

        function found = entityMethods(obj)
            %entityMethods The module's methods: a row of nansen.Method
            found = nansen.Method.empty(1, 0);
            for document = obj.documents("methods", "nansen.method")
                found(end + 1) = nansen.Method(document{1}, obj.MatlabRoot, obj.Id); %#ok<AGROW>
            end
        end

        function summary = summary(obj)
            summary = struct("id", char(obj.Id), "version", char(obj.Version), ...
                "title", char(nansen.internal.getField(obj.Document, "title", obj.Id)), ...
                "description", char(nansen.internal.getField(obj.Document, "description", "")), ...
                "folder", char(obj.Folder));
        end
    end

    methods (Access = private)
        function documents = documents(obj, key, schemaType)
            documents = {};
            for relative = nansen.internal.asCellstr(nansen.internal.getField(obj.Document, key, {}))
                documents{end + 1} = nansen.readDocument(fullfile(obj.Folder, relative{1}), ExpectedType=schemaType); %#ok<AGROW>
            end
        end
    end

    methods (Static)
        function obj = read(folder)
            arguments
                folder (1,1) string
            end
            obj = nansen.Module(folder, nansen.readDocument(fullfile(folder, "module.nansen.json"), ...
                ExpectedType="nansen.module"));
        end

        function folder = builtInFolder()
            %builtInFolder The modules that ship with NANSEN
            folder = string(fullfile(nansen.internal.repoRoot(), "modules"));
        end

        function module = resolve(entry, projectFolder)
            %resolve Find a module listed in a project: its path, else <project>/modules/<id>, else the built-in modules
            id = string(entry.id);
            if isfield(entry, "path")
                path = string(entry.path);
                if ~nansen.internal.isAbsolutePath(path)
                    path = string(fullfile(projectFolder, path));
                end
                candidates = path;
            else
                candidates = [string(fullfile(projectFolder, "modules", id)), ...
                    string(fullfile(nansen.Module.builtInFolder(), id))];
            end
            for candidate = candidates
                if isfile(fullfile(candidate, "module.nansen.json"))
                    module = nansen.Module.read(candidate);
                    if module.Id ~= id
                        nansen.internal.throwError("module-mismatch", "%s holds module '%s', not '%s'", candidate, module.Id, id)
                    end
                    return
                end
            end
            nansen.internal.throwError("unknown-module", "module '%s' not found (looked in %s)", id, strjoin(candidates, ", "))
        end
    end
end
