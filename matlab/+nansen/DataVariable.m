classdef DataVariable
%DataVariable A named piece of an entity's data: where its file is, and which adapter reads it
%
%   See schema/data-variable.schema.json.

    properties (SetAccess = private)
        Document (1,1) struct
        Name (1,1) string
        EntityType (1,1) string
        DataLocation (1,1) string
        FilePattern (1,1) string = ""
        FileName (1,1) string = ""
        Subfolder (1,1) string = ""
        FileAdapter (1,1) string
        VariableInFile (1,1) string = ""   % the variable of a .mat file it is, when the file holds several
    end

    methods
        function obj = DataVariable(document)
            arguments
                document (1,1) struct
            end
            field = @(name) string(nansen.internal.getField(document, name, ""));
            obj.Document = document;
            obj.Name = field("name");
            obj.EntityType = field("entityType");
            obj.DataLocation = field("dataLocation");
            obj.FilePattern = field("filePattern");
            obj.FileName = field("fileName");
            obj.Subfolder = field("subfolder");
            obj.FileAdapter = field("fileAdapter");
            obj.VariableInFile = field("variableInFile");
        end

        function value = inFile(obj, value, path)
            %inFile The variable's part of what its file holds: the whole, or the variable named VariableInFile
            if obj.VariableInFile == ""
                return
            end
            if ~(isstruct(value) && isscalar(value) && isfield(value, obj.VariableInFile))
                nansen.internal.throwError("data-not-found", "%s has no variable '%s' (for '%s')", path, obj.VariableInFile, obj.Name)
            end
            value = value.(obj.VariableInFile);
        end

        function relative = relativeFile(obj, values)
            %relativeFile subfolder/fileName with the tokens filled, relative to the entity's folder
            if obj.FileName == ""
                nansen.internal.throwError("no-file-name", ...
                    "data variable '%s' has no fileName, so it cannot be written", obj.Name)
            end
            relative = nansen.internal.fillTemplate(obj.FileName, values, obj.Name);
            if obj.Subfolder ~= ""
                relative = obj.Subfolder + "/" + relative;
            end
        end
    end
end
