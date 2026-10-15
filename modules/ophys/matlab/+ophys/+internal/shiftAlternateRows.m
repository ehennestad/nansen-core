function out = shiftAlternateRows(chunk, k)
%shiftAlternateRows Rows 2, 4, ... moved by -k columns: out(r, c) = chunk(r, c + k) on those rows, 0 outside the frame
    out = chunk;
    if k == 0
        return
    end
    width = size(chunk, 2);
    index = repmat({':'}, 1, max(3, ndims(chunk)));
    index{1} = 2:2:size(chunk, 1);
    out(index{:}) = 0;
    first = max(0, -k);
    stop = min(width, width - k);
    target = index;
    source = index;
    target{2} = first + 1:stop;
    source{2} = first + k + 1:stop + k;
    out(target{:}) = chunk(source{:});
end
