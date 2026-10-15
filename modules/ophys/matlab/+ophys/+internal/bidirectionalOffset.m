function offset = bidirectionalOffset(image, most)
%bidirectionalOffset The column offset k of the lines scanned back (rows 2, 4, ...) from those scanned forth (rows 1, 3, ...)
%
%   The k within most whose shift makes the two sets of lines correlate
%   best (Pearson, over the columns both cover); of equal ones, the
%   smallest, then the negative. As Python's bidirectional_offset.
    forth = image(1:2:end, :);
    back = image(2:2:end, :);
    rows = min(size(forth, 1), size(back, 1));
    forth = forth(1:rows, :);
    back = back(1:rows, :);
    width = size(image, 2);
    ks = -most:most;
    [~, order] = sortrows([abs(ks(:)), ks(:)]);
    best = -Inf;
    offset = 0;
    for k = ks(order)
        first = max(0, -k);
        stop = min(width, width - k);
        if stop - first < 2
            continue
        end
        score = ophys.internal.pearsonOf(forth(:, first + 1:stop), back(:, first + k + 1:stop + k));
        if score > best
            best = score;
            offset = k;
        end
    end
end
