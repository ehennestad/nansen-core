classdef Csv < nansen.FileAdapter
%Csv A table in a CSV file, read as a MATLAB table
%
%   Numeric columns are doubles (NaN where empty), others strings, with the
%   column names as written. Written from a table or a scalar struct of
%   columns. Python's CsvAdapter reads the same file as {name: [values]}.
    methods
        function data = read(~, path)
            data = nansen.adapters.Csv.readTable(path, "text");
        end

        function write(~, path, data)
            writetable(nansen.adapters.Csv.asTable(data), path, FileType="text", Delimiter=",");
        end
    end

    methods (Static)
        function data = readTable(path, fileType)
            %readTable A table file's first sheet as a table: names kept, text as strings
            options = detectImportOptions(path, FileType=fileType, VariableNamingRule="preserve", TextType="string");
            if fileType == "text"
                options.Delimiter = ",";
            end
            data = readtable(path, options);
        end

        function data = asTable(data)
            %asTable A table, from a table or a scalar struct of equally long columns
            if isstruct(data) && isscalar(data)
                names = fieldnames(data);
                columns = cellfun(@(n) reshape(data.(n), [], 1), names, UniformOutput=false);
                data = table(columns{:}, VariableNames=names);
            end
            if ~istable(data)
                nansen.internal.throwError("invalid-params", "a table file is written from a table or a struct of columns")
            end
        end
    end
end
