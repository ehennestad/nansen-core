function out = fillHoles(mask)
%fillHoles Background not 4-connected to the image border becomes foreground
    [height, width] = size(mask);
    outside = false(height, width);
    queue = zeros(0, 2);
    border = [[(1:height)', ones(height, 1)]; [(1:height)', repmat(width, height, 1)]; ...
        [ones(width, 1), (1:width)']; [repmat(height, width, 1), (1:width)']];
    for i = 1:size(border, 1)
        y = border(i, 1);
        x = border(i, 2);
        if ~mask(y, x) && ~outside(y, x)
            outside(y, x) = true;
            queue(end + 1, :) = [y, x]; %#ok<AGROW>
        end
    end
    steps = [-1, 0; 1, 0; 0, -1; 0, 1];
    while ~isempty(queue)
        here = queue(end, :);
        queue(end, :) = [];
        for n = 1:4
            ny = here(1) + steps(n, 1);
            nx = here(2) + steps(n, 2);
            if ny >= 1 && ny <= height && nx >= 1 && nx <= width && ~mask(ny, nx) && ~outside(ny, nx)
                outside(ny, nx) = true;
                queue(end + 1, :) = [ny, nx]; %#ok<AGROW>
            end
        end
    end
    out = ~outside;
end
