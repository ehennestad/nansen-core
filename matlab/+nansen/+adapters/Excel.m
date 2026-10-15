classdef Excel < nansen.FileAdapter
%Excel A table in the first sheet of an Excel workbook (.xlsx), read as a MATLAB table
%
%   As nansen.adapters.Csv reads a CSV file. Python's ExcelAdapter reads the
%   same file as {name: [values]} (with openpyxl).
    methods
        function data = read(~, path)
            data = nansen.adapters.Csv.readTable(path, "spreadsheet");
        end

        function write(~, path, data)
            if isfile(path)
                delete(path);   % writetable would keep the old workbook's other cells
            end
            writetable(nansen.adapters.Csv.asTable(data), path, FileType="spreadsheet");
        end
    end
end
