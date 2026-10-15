function share = overlapShare(a, b)
%overlapShare The share of the smaller of two pixel lists (N-by-2) that the other covers
    common = size(intersect(a, b, "rows"), 1);
    share = common / min(size(a, 1), size(b, 1));
end
