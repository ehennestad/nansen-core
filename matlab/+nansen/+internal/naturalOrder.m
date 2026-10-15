function paths = naturalOrder(paths)
%naturalOrder Paths sorted with their runs of digits compared as numbers: part2 before part10
%
%   Python's nansen.stacks.natural_order gives the same order: each run of
%   digits is compared as its number, the rest as text.
    paths = reshape(string(paths), 1, []);
    keys = strings(size(paths));
    for i = 1:numel(paths)
        [digits, text] = regexp(paths(i), "\d+", "match", "split");
        key = text(1);
        for k = 1:numel(digits)
            key = key + pad(digits(k), max(20, strlength(digits(k))), "left", "0") + text(k + 1);
        end
        keys(i) = key;
    end
    [~, order] = sort(keys);
    paths = paths(order);
end
