function inside = inPolygon(xs, ys, px, py)
%inPolygon Even-odd rule: is the point (px, py) inside the polygon of vertices (xs, ys)? As Python's ophys_adapters.in_polygon
    inside = false;
    j = numel(xs);
    for i = 1:numel(xs)
        if (ys(i) > py) ~= (ys(j) > py) && px < (xs(j) - xs(i)) * (py - ys(i)) / (ys(j) - ys(i)) + xs(i)
            inside = ~inside;
        end
        j = i;
    end
end
