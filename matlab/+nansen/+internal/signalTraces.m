function result = signalTraces(names, arrays, columns, start, stop, maxPoints)
%signalTraces Columns of frames x N signal arrays (a vector is one column), for the dashboard's trace plot
%
%   names and arrays are cell arrays of the variables' names and values;
%   columns are 0-based. Frames start..stop-1 (0-based, cut to the longest
%   array; stop [] for all) are taken every step-th, step the smallest that
%   keeps it to maxPoints. Values are rounded to 4 decimals as
%   floor(v * 10000 + 0.5) / 10000; NaN, infinities and frames past an
%   array's end are null. Python's nansen.frames.signal_traces gives the same.
    frames = 0;
    for i = 1:numel(arrays)
        data = arrays{i};
        if ~(isnumeric(data) || islogical(data)) || ~isreal(data) || ~ismatrix(data)
            nansen.internal.throwError("invalid-data", "%s is not a frames x signals array", names{i})
        end
        if isrow(data) && ~isscalar(data)
            data = data(:);   % a 1-D array read from a file is a column
        end
        arrays{i} = double(data);
        frames = max(frames, size(arrays{i}, 1));
    end
    start = min(max(0, double(start)), frames);
    if isempty(stop)
        stop = frames;
    else
        stop = min(max(start, double(stop)), frames);
    end
    maxPoints = max(1, double(maxPoints));
    step = max(1, ceil((stop - start) / maxPoints));
    picked = start:step:stop - 1;
    traces = cell(1, numel(arrays));
    for i = 1:numel(arrays)
        data = arrays{i};
        out = cell(1, numel(columns));
        for k = 1:numel(columns)
            column = double(columns(k));
            if column < 0 || column >= size(data, 2) || column ~= round(column)
                nansen.internal.throwError("invalid-params", "%s has %d columns; column %d is not one", names{i}, size(data, 2), column)
            end
            values = nan(1, numel(picked));
            inside = picked < size(data, 1);
            values(inside) = floor(data(picked(inside) + 1, column + 1) * 10000 + 0.5) / 10000;
            values(~isfinite(values)) = NaN;
            out{k} = struct("column", column, "values", {num2cell(values)});   % NaN is written as null
        end
        traces{i} = struct("variable", char(names{i}), "columns", {out}, "count", size(data, 2));
    end
    result = struct("frames", frames, "start", start, "step", step, "points", numel(picked), "traces", {traces});
end
