function found = components(mask, connectivity)
%components The 4- (or 8-) connected areas of a logical image, each as its [row, column] pixels (1-based) in row-major order
%
%   Areas come in the row-major order of their first pixel, as in Python.
    if nargin < 2
        connectivity = 4;
    end
    steps = [-1, 0; 1, 0; 0, -1; 0, 1];
    if connectivity == 8
        steps = [-1, -1; -1, 0; -1, 1; 0, -1; 0, 1; 1, -1; 1, 0; 1, 1];
    end
    [height, width] = size(mask);
    seen = false(height, width);
    found = {};
    seeds = find(mask.');   % the transpose lists the pixels row by row
    for i = 1:numel(seeds)
        [x, y] = ind2sub([width, height], seeds(i));
        if seen(y, x)
            continue
        end
        seen(y, x) = true;
        queue = [y, x];
        pixels = zeros(0, 2);
        while ~isempty(queue)
            here = queue(end, :);
            queue(end, :) = [];
            pixels(end + 1, :) = here; %#ok<AGROW>
            neighbours = here + steps;
            for n = 1:size(steps, 1)
                ny = neighbours(n, 1);
                nx = neighbours(n, 2);
                if ny >= 1 && ny <= height && nx >= 1 && nx <= width && mask(ny, nx) && ~seen(ny, nx)
                    seen(ny, nx) = true;
                    queue(end + 1, :) = [ny, nx]; %#ok<AGROW>
                end
            end
        end
        found{end + 1} = sortrows(pixels); %#ok<AGROW>
    end
end
