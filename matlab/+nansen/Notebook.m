classdef Notebook
%Notebook Notes on entities: what dev keeps in each session's and subject's Notebook
%
%   A notebook holds the notes on one entity type's entities, at
%   notes/<entityType>.notebook.nansen.json in the project. A note is about
%   one entity, named by its key, and has a time, an author, a type, a title,
%   text, and the #tags written in them. Get one with project.notebook(type).
%   Python's nansen.notebook does the same.
%
%   Notes are structs with the fields id, key, createdAt, author, type,
%   title, text and tags (a cell row of char).

    properties (Constant)
        Types = ["informal", "important", "todo", "question"]
    end

    properties (SetAccess = immutable)
        Path (1,1) string
        EntityType (1,1) string
        KeyNames (1,:) string
    end

    methods
        function obj = Notebook(path, entityType, keyNames)
            obj.Path = path;
            obj.EntityType = entityType;
            obj.KeyNames = reshape(string(keyNames), 1, []);
        end

        function key = checkKey(obj, key)
            %checkKey The key as a struct of the key columns, in order; invalid-params if it is not one
            if ~isstruct(key) || ~isscalar(key) || ~isequal(sort(string(fieldnames(key)))', sort(obj.KeyNames))
                nansen.internal.throwError("invalid-params", "a key of %s has the columns %s", ...
                    obj.EntityType, strjoin(obj.KeyNames, ", "))
            end
            ordered = struct();
            for name = obj.KeyNames
                value = key.(name);
                if (ischar(value) && (isrow(value) || isempty(value))) || (isstring(value) && isscalar(value))
                    ordered.(name) = char(value);
                elseif isnumeric(value) && isscalar(value) && value == round(value)
                    ordered.(name) = double(value);
                else
                    nansen.internal.throwError("invalid-params", "key column '%s' must be text or an integer", name)
                end
            end
            key = ordered;
        end

        function notes = notes(obj, key)
            %notes Notes, newest first, as a cell row of structs; only the entity's when a key is given
            arguments
                obj
                key = []
            end
            document = obj.read();
            notes = flip(document.notes);
            if ~isempty(key)
                key = obj.checkKey(key);
                notes = notes(cellfun(@(note) sameKey(note.key, key, obj.KeyNames), notes));
            end
        end

        function note = add(obj, key, text, options)
            arguments
                obj
                key
                text = ""
                options.Title = ""
                options.Type = "informal"
                options.Author = []
            end
            key = obj.checkKey(key);
            type = string(options.Type);
            if ~isscalar(type) || ~ismember(type, nansen.Notebook.Types)
                nansen.internal.throwError("invalid-params", "a note's type is one of %s, not '%s'", ...
                    strjoin(nansen.Notebook.Types, ", "), strjoin(type, " "))
            end
            title = char(options.Title);
            text = char(text);
            if strtrim(string(text)) == "" && strtrim(string(title)) == ""
                nansen.internal.throwError("invalid-params", "a note needs a title or text")
            end
            author = options.Author;
            if isempty(author) && ~ischar(author) && ~isstring(author)
                author = nansen.Notebook.defaultAuthor();
            end
            document = obj.read();
            note = struct("id", document.nextId, "key", key, ...
                "createdAt", char(datetime("now", Format="yyyy-MM-dd'T'HH:mm:ss")), ...
                "author", char(author), "type", char(type), "title", title, "text", text, ...
                "tags", {cellstr(nansen.Notebook.tagsOf(title, text))});
            document.notes{end + 1} = note;
            document.nextId = document.nextId + 1;
            obj.write(document)
        end

        function remove(obj, id)
            document = obj.read();
            keep = cellfun(@(note) note.id ~= id, document.notes);
            if all(keep)
                nansen.internal.throwError("unknown-note", "the %s notebook has no note %d", obj.EntityType, id)
            end
            document.notes = document.notes(keep);
            obj.write(document)
        end
    end

    methods (Static)
        function tags = tagsOf(varargin)
            %tagsOf The words written as #tag, in order, each once (a string row)
            tags = strings(1, 0);
            for i = 1:nargin
                found = regexp(char(varargin{i}), "#([A-Za-z0-9_]+)", "tokens");
                for j = 1:numel(found)
                    tag = string(found{j}{1});
                    if ~ismember(tag, tags)
                        tags(end + 1) = tag; %#ok<AGROW>
                    end
                end
            end
        end

        function author = defaultAuthor()
            %defaultAuthor The user name, as Python's getpass.getuser finds it in the environment
            author = "";
            for name = ["LOGNAME", "USER", "LNAME", "USERNAME"]
                author = string(getenv(name));
                if author ~= ""
                    return
                end
            end
        end
    end

    methods (Access = private)
        function document = read(obj)
            if ~isfile(obj.Path)
                entry = nansen.internal.schemaEntry("nansen.notebook");
                document = struct("schemaType", 'nansen.notebook', "schemaVersion", char(entry.version), ...
                    "entityType", char(obj.EntityType), "nextId", 1, "notes", {{}});
                return
            end
            document = nansen.readDocument(obj.Path, ExpectedType="nansen.notebook");
            notes = nansen.internal.asCellOfStructs(document.notes);
            for i = 1:numel(notes)
                notes{i}.tags = nansen.internal.asCellstr(notes{i}.tags);
            end
            document.notes = notes;
        end

        function write(obj, document)
            folder = fileparts(obj.Path);
            if ~isfolder(folder)
                mkdir(folder);
            end
            nansen.checkDocument(document, ExpectedType="nansen.notebook");
            nansen.internal.writeJson(obj.Path, document)
        end
    end
end

function tf = sameKey(a, b, names)
    tf = true;
    for name = names
        x = a.(name);
        y = b.(name);
        if (ischar(x) || isstring(x)) && (ischar(y) || isstring(y))
            tf = string(x) == string(y);
        elseif isnumeric(x) && isnumeric(y)
            tf = x == y;
        else
            tf = false;
        end
        if ~tf
            return
        end
    end
end
