classdef Fragment
%Fragment A fragment definition: a named, versioned group of columns
%
%   fragment = nansen.Fragment.read(path) or nansen.Fragment(document)
%   with a decoded nansen.fragment document.

    properties (SetAccess = private)
        Id (1,1) string
        Version (1,1) string
        Columns (1,:) nansen.Column = nansen.Column.empty(1, 0)
        % Default value of each column that declares one, by column name
        Defaults (1,1) struct = struct()
        Document struct
    end

    methods
        function obj = Fragment(document)
            arguments
                document (1,1) struct
            end
            obj.Document = document;
            obj.Id = string(document.id);
            obj.Version = string(document.version);
            definitions = nansen.internal.asCellOfStructs(document.columns);
            columns = cell(1, numel(definitions));
            for i = 1:numel(definitions)
                columns{i} = nansen.Column.fromStruct(definitions{i});
                columns{i}.Fragment = obj.Id;
                if isfield(definitions{i}, "default")
                    obj.Defaults.(definitions{i}.name) = definitions{i}.default;
                end
            end
            obj.Columns = [columns{:}];
        end
    end

    methods (Static)
        function obj = read(path)
            obj = nansen.Fragment(nansen.readDocument(path, ExpectedType="nansen.fragment"));
        end
    end
end
