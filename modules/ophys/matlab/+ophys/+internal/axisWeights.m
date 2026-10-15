function weights = axisWeights(edges, size_)
%axisWeights For each pixel along an axis: the patches whose centres it lies between, and how far from the first (0..1)
%
%   A struct of first and second (patch numbers, from 1) and share, each
%   size_ x 1. Pixels before the first centre or after the last take that
%   patch's shift.
    centres = (edges(1:end - 1) + edges(2:end) - 1) / 2;
    first = ones(size_, 1);
    second = ones(size_, 1);
    share = zeros(size_, 1);
    for y = 0:size_ - 1
        if y <= centres(1)
            continue
        end
        if y >= centres(end)
            first(y + 1) = numel(centres);
            second(y + 1) = numel(centres);
            continue
        end
        k = find(centres <= y, 1, "last");
        first(y + 1) = k;
        second(y + 1) = k + 1;
        share(y + 1) = (y - centres(k)) / (centres(k + 1) - centres(k));
    end
    weights = struct("first", first, "second", second, "share", share);
end
