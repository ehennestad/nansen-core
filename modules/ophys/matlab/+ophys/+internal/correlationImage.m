function image = correlationImage(stack)
%correlationImage Each pixel's average Pearson correlation with its in-frame 8 neighbours over time
    [height, width, ~] = size(stack);
    data = double(stack);
    data = data - mean(data, 3);
    spread = sqrt(mean(data .^ 2, 3));
    data = data ./ spread;
    data(isnan(data)) = 0;   % a pixel that does not change
    total = zeros(height, width);
    count = zeros(height, width);
    for dy = -1:1
        for dx = -1:1
            if dy == 0 && dx == 0
                continue
            end
            hereRows = max(1, 1 - dy):min(height, height - dy);
            hereColumns = max(1, 1 - dx):min(width, width - dx);
            thereRows = max(1, 1 + dy):min(height, height + dy);
            thereColumns = max(1, 1 + dx):min(width, width + dx);
            total(hereRows, hereColumns) = total(hereRows, hereColumns) + ...
                mean(data(hereRows, hereColumns, :) .* data(thereRows, thereColumns, :), 3);
            count(hereRows, hereColumns) = count(hereRows, hereColumns) + 1;
        end
    end
    image = total ./ count;
    image(count == 0) = 0;
end
