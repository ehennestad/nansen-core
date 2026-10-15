classdef SessionShim < dynamicprops
%SessionShim NANSEN dev's session object over an entity, for dev's session methods to run unchanged
%
%   session = nansen.legacy.SessionShim(entity, context) stands in for
%   dev's nansen.metadata.type.Session when nansen.runMethod runs an
%   imported dev session method (legacySessionMethod). It offers what those
%   methods use of a session:
%
%   - the entity's values as properties: sessionID, subjectID, Date, Time,
%     Ignore and Description from session_id, subject_id, session_date,
%     session_time, ignore and description, and every other value (key,
%     DSM attribute or table column) under its own name;
%   - loadData(varName), saveData(varName, data, Name=Value...),
%     getDataFilePath(varName, '-r'|'-w', Name=Value...), existVariable,
%     validateVariable, getSessionFolder(dataLocation, mode),
%     existSessionFolder, createSessionFolder, getDataLocationRootDir,
%     getDataId and toStruct, as dev's.
%
%   A dev variable name is the project's data variable of that name, of
%   any case, or with underscores left out (RoiArray, roi_array). A
%   variable saved for the first time is made as dev's createVariable made
%   one: <sessionID>_<name in snake case>.mat in the first data location
%   that can be written (DataLocation=, Subfolder=, FileType= .mat, .json
%   or .txt, FileNameExpression= as dev's), and a .mat file holds it as a
%   variable of its name. A dev data location name is the location of
%   that identifier or display name. getSessionFolder() without a location
%   gives the entity's folder in the first location it has one in (dev
%   used its default data location).

    properties
        sessionID = ''
        subjectID = ''
        Date = NaT
        Time = []
        Ignore = false
        Description = ''
        Experiment = ''
        Protocol = ''
    end

    properties (SetAccess = private)
        Entity = []     % the nansen.Entity
        Context = []    % the nansen.MethodContext of the run
        Project = []    % the nansen.Project the entity is of
    end

    methods
        function obj = SessionShim(entity, context)
            arguments
                entity (1,1) nansen.Entity
                context = []
            end
            obj.Entity = entity;
            obj.Context = context;
            project = entity.Project;
            if isempty(project) && ~isempty(context)
                project = context.Project;
            end
            obj.Project = project;
            values = entity.values();
            for name = reshape(string(fieldnames(values)), 1, [])
                obj.assignValue(name, values.(name));
            end
        end

        function id = getDataId(obj)
            id = obj.sessionID;
        end

        function values = toStruct(obj)
            values = obj.Entity.values();
        end

        % -- data ----------------------------------------------------------------------------

        function data = loadData(obj, varName, varargin) %#ok<INUSD>
            %loadData The variable's data, read with its file adapter (dev's Default .mat: the variable of its name)
            %   dev's name-value options only describe a variable its model lacks, which has no data to load
            variable = obj.findVariable(varName);
            if isempty(variable)
                error("NANSEN:Session:VariableNotFound", "Variable '%s' was not found.", varName)
            end
            try
                data = obj.requireProject().load(obj.Entity, variable.Name);
            catch err
                if isa(err, "nansen.NansenError") && err.Code == "data-not-found"
                    error("NANSEN:Session:VariableNotFound", "Variable '%s' was not found.", varName)
                end
                rethrow(err)
            end
            if variable.FileAdapter == "mat" && variable.VariableInFile == "" && isstruct(data) && isscalar(data) ...
                    && isfield(data, char(varName))
                data = data.(char(varName));
            end
        end

        function saveData(obj, varName, data, varargin)
            %saveData Write the variable's data; a variable the project has not got is made first, as dev's
            variable = obj.findVariable(varName);
            if isempty(variable)
                document = obj.newVariableDocument(varName, varargin{:});
                obj.requireProject().addDataVariable(document);
                variable = nansen.DataVariable(document);
            end
            if variable.FileAdapter == "mat" && variable.VariableInFile == "" && isvarname(char(varName))
                data = struct(char(varName), {data});   % dev's Default: a variable of its name in the .mat file
            end
            obj.requireProject().save(obj.Entity, variable.Name, data);
        end

        function [pathStr, variableInfo] = getDataFilePath(obj, varName, varargin)
            %getDataFilePath The variable's file: the one there is, or where it is written ('-w' makes its folder)
            mode = "read";
            if ~isempty(varargin) && (ischar(varargin{1}) || isstring(varargin{1})) && ismember(string(varargin{1}), ["-r", "-w"])
                if string(varargin{1}) == "-w"
                    mode = "write";
                end
                varargin(1) = [];
            end
            project = obj.requireProject();
            variable = obj.findVariable(varName);
            if isempty(variable)
                document = obj.newVariableDocument(varName, varargin{:});
                if mode == "write"   % dev keeps a variable in its model once a path is asked for to write it
                    project.addDataVariable(document);
                end
                variable = nansen.DataVariable(document);
            end
            pathStr = "";
            if isfile(project.dataVariablePath(variable.Name))
                paths = project.existingFiles(obj.Entity, variable.Name);
                if ~isempty(paths)
                    pathStr = paths(1);
                end
            end
            if pathStr == ""
                pathStr = obj.writePathOf(variable);
            end
            if mode == "write" && ~isfolder(fileparts(pathStr))
                mkdir(fileparts(pathStr));
            end
            pathStr = char(pathStr);
            if nargout > 1
                [~, ~, extension] = fileparts(pathStr);
                variableInfo = struct("VariableName", char(varName), "DataLocation", char(variable.DataLocation), ...
                    "Subfolder", char(variable.Subfolder), "FileNameExpression", '', "FileType", extension, ...
                    "FileAdapter", char(variable.FileAdapter), "PathInFile", char(variable.VariableInFile));
            end
        end

        function tf = existVariable(obj, varName)
            tf = isfile(obj.getDataFilePath(varName));
        end

        function validateVariable(obj, variableName)
            %validateVariable dev's check that the variables' files are there (NANSEN:Session:RequiredDataMissing)
            names = string(variableName);   % a name, or a cell of names
            for name = reshape(names, 1, [])
                if ~obj.existVariable(name)
                    error("NANSEN:Session:RequiredDataMissing", ...
                        "The file containing ""%s"" does not exist or was not found for session ""%s""", name, obj.sessionID)
                end
            end
        end

        % -- folders -------------------------------------------------------------------------

        function folderPath = getSessionFolder(obj, dataLocationName, mode)
            %getSessionFolder The entity's folder in a data location; 'create' makes it in a location that can
            %   be written, 'force' in any (dev's modes); NANSEN:Session:FolderNotFound when there is none
            if nargin < 2 || isempty(dataLocationName) || string(dataLocationName) == ""
                location = obj.defaultLocation();
                dataLocationName = location;
            else
                location = obj.locationId(dataLocationName);
            end
            if nargin < 3
                mode = 'nocreate';
            end
            mode = string(validatestring(mode, {'create', 'nocreate', 'force'}));
            dataset = obj.requireProject().requireDataset();
            folderPath = "";
            entry = obj.Entity.location(location);
            if ~isempty(entry) && ~isempty(nansen.internal.getField(entry, "paths", []))
                paths = sort(string(nansen.internal.asCellstr(entry.paths)));
                folderPath = dataset.absolute(location, paths(1));
                if isfile(folderPath)   % a level that is a file: its folder, as dev
                    folderPath = string(fileparts(folderPath));
                end
            end
            if folderPath == ""   % none when it was scanned: where it is made (DSM's path), which may be there by now
                try
                    folderPath = dataset.absolute(location, dataset.generatePath(location, obj.Entity.EntityType, obj.Entity.values()));
                catch
                    folderPath = "";   % DSM cannot make one there (a read-only location, no folder names)
                end
            end
            if folderPath ~= "" && ~isfolder(folderPath) && ((mode == "create" && obj.isWritable(location)) || mode == "force")
                mkdir(folderPath);
            end
            if folderPath == "" || ~isfolder(folderPath)
                error("NANSEN:Session:FolderNotFound", "Session folder at ""%s"" does not exist for session %s", ...
                    dataLocationName, obj.sessionID)
            end
            folderPath = regexprep(char(folderPath), '[\\/]+$', '');
        end

        function tf = existSessionFolder(obj, dataLocationName)
            tf = true;
            try
                obj.getSessionFolder(dataLocationName);
            catch err
                if err.identifier ~= "NANSEN:Session:FolderNotFound"
                    rethrow(err)
                end
                tf = false;
            end
        end

        function folderPath = createSessionFolder(obj, dataLocationName)
            folderPath = obj.getSessionFolder(dataLocationName, 'force');
        end

        function folderPath = getDataLocationRootDir(obj, dataLocationName)
            root = obj.requireProject().requireDataset().root(obj.locationId(dataLocationName));
            folderPath = char(root.Path);
        end
    end

    methods (Access = private)
        function assignValue(obj, name, value)
            % A value as dev's property of it: its own, or a dynamic property of its name
            devNames = struct("session_id", "sessionID", "subject_id", "subjectID", "session_date", "Date", ...
                "session_time", "Time", "ignore", "Ignore", "description", "Description");
            target = name;
            if isfield(devNames, name)
                target = devNames.(name);
            end
            if ismember(target, ["Entity", "Context", "Project"]) || ismethod(obj, char(target))
                return
            end
            if isstring(value) && isscalar(value)
                if ismissing(value)
                    value = '';
                else
                    value = char(value);
                end
            end
            if target == "Date" && ischar(value) && ~isempty(value)
                try
                    value = datetime(value, InputFormat="yyyy-MM-dd");
                catch
                end
            end
            if ~isprop(obj, char(target))
                try
                    addprop(obj, char(target));
                catch
                    return   % not a name a property can have
                end
            end
            obj.(char(target)) = value;
        end

        function project = requireProject(obj)
            project = obj.Project;
            if isempty(project)
                error("nansen:SessionShim:NoProject", "The session's entity is not of a project, so its data cannot be read or written")
            end
        end

        function variable = findVariable(obj, varName)
            % The project's data variable for a dev variable name: the same name, of any case, or without underscores
            variable = [];
            candidates = obj.requireProject().dataVariables(obj.Entity.EntityType);
            if isempty(candidates)
                return
            end
            names = [candidates.Name];
            name = string(varName);
            match = find(names == name, 1);
            if isempty(match)
                match = find(lower(names) == lower(name), 1);
            end
            if isempty(match)
                match = find(lower(erase(names, "_")) == lower(erase(name, "_")), 1);
            end
            if ~isempty(match)
                variable = candidates(match);
            end
        end

        function document = newVariableDocument(obj, varName, varargin)
            % dev's variable for a name its model lacks: <sessionID>_<name in snake case><FileType>, in the
            % DataLocation given or the first that can be written, with its Subfolder and FileNameExpression
            given = struct();
            for k = 1:2:numel(varargin) - 1
                if (ischar(varargin{k}) || isstring(varargin{k})) && isvarname(char(varargin{k}))
                    given.(char(varargin{k})) = varargin{k + 1};
                end
            end
            text = @(field) string(nansen.internal.getField(given, field, ""));
            if text("DataLocation") ~= ""
                location = obj.locationId(text("DataLocation"));
            else
                location = obj.firstWritable();
            end
            fileType = text("FileType");
            if fileType == ""
                fileType = ".mat";
            elseif ~startsWith(fileType, ".")
                fileType = "." + fileType;
            end
            adapters = struct("mat", "mat", "json", "json", "txt", "text");
            extension = lower(extractAfter(fileType, 1));
            if ~isvarname(char(extension)) || ~isfield(adapters, extension)
                nansen.internal.throwError("unknown-file-adapter", "no built-in file adapter for dev's '%s' as %s files", varName, fileType)
            end
            base = snakeOf(varName);
            if text("FileNameExpression") ~= ""
                base = text("FileNameExpression");
            end
            key = obj.Entity.Key;
            idField = "session_id";
            if ~isfield(key, idField)
                fields = string(fieldnames(key));
                idField = fields(end);
            end
            entry = nansen.internal.schemaEntry("nansen.dataVariable");
            document = struct("schemaType", 'nansen.dataVariable', "schemaVersion", char(entry.version), ...
                "name", char(varName), "entityType", char(obj.Entity.EntityType), "dataLocation", char(location));
            subfolder = regexprep(replace(text("Subfolder"), "\", "/"), "^/+|/+$", "");
            if subfolder ~= ""
                document.subfolder = char(subfolder);
            end
            document.fileName = char("{" + idField + "}_" + base + fileType);
            document.fileAdapter = char(adapters.(extension));
            if extension == "mat" && isvarname(char(varName))
                document.variableInFile = char(varName);   % dev saved it as a variable of its name
            end
        end

        function path = writePathOf(obj, variable)
            % Where the variable is written for the entity, for a variable the project may not have yet
            project = obj.requireProject();
            if isfile(project.dataVariablePath(variable.Name))
                path = project.writePath(obj.Entity, variable.Name);
                return
            end
            dataset = project.requireDataset();
            values = obj.Entity.values();
            entry = obj.Entity.location(variable.DataLocation);
            if ~isempty(entry) && string(nansen.internal.getField(entry, "fileSystemType", "folder")) == "folder" ...
                    && ~isempty(nansen.internal.getField(entry, "paths", []))
                paths = sort(string(nansen.internal.asCellstr(entry.paths)));
                folder = paths(1);
            else
                folder = dataset.generatePath(variable.DataLocation, obj.Entity.EntityType, values);
            end
            path = dataset.absolute(variable.DataLocation, folder + variable.relativeFile(values));
        end

        function id = locationId(obj, name)
            % The data location of a dev location name: its identifier or display name, of any case
            name = string(name);
            locations = obj.requireProject().requireDataset().Config.locations();
            identifiers = string(cellfun(@(l) char(l.identifier), locations, UniformOutput=false));
            labels = string(cellfun(@(l) char(nansen.internal.getField(l, "displayName", "")), locations, UniformOutput=false));
            simple = @(s) lower(regexprep(s, "[^A-Za-z0-9]+", "_"));
            match = find(identifiers == name, 1);
            if isempty(match)
                match = find(lower(labels) == lower(name) | lower(identifiers) == lower(name), 1);
            end
            if isempty(match)
                match = find(simple(identifiers) == simple(name), 1);
            end
            if isempty(match)
                nansen.internal.throwError("unknown-location", "the dataset has no data location '%s'", name)
            end
            id = identifiers(match);
        end

        function id = firstWritable(obj)
            locations = obj.requireProject().requireDataset().Config.locations();
            for i = 1:numel(locations)
                if string(nansen.internal.getField(locations{i}, "access", "read")) == "readwrite"
                    id = string(locations{i}.identifier);
                    return
                end
            end
            nansen.internal.throwError("unknown-data-variable", "no data location can be written to make a data variable in")
        end

        function id = defaultLocation(obj)
            % The first location the entity has a folder in, else the first that can be written
            for entry = obj.Entity.locations()
                if ~isempty(nansen.internal.getField(entry{1}, "paths", []))
                    id = string(entry{1}.dataLocationIdentifier);
                    return
                end
            end
            id = obj.firstWritable();
        end

        function tf = isWritable(obj, location)
            tf = false;
            for item = obj.requireProject().requireDataset().Config.locations()
                if string(item{1}.identifier) == location
                    tf = string(nansen.internal.getField(item{1}, "access", "read")) == "readwrite";
                end
            end
        end
    end
end

function text = snakeOf(name)
    % dev's camel2snake, as the legacy importer names files: an underscore before each capital or digit, lower case
    name = char(name);
    text = '';
    for k = 1:numel(name)
        if k > 1 && (isstrprop(name(k), 'upper') || any(name(k) == '123456789'))
            text = [text, '_']; %#ok<AGROW>
        end
        text = [text, name(k)]; %#ok<AGROW>
    end
    text = string(lower(text));
end
