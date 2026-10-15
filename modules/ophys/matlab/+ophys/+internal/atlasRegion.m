function label = atlasRegion(atlas, ml, ap)
%atlasRegion The label of the atlas region at (ml, ap) mm, or [] outside every region
    label = [];
    column = floor((ml - atlas.origin(1)) * atlas.pixelsPerMm);
    row = floor((ap - atlas.origin(2)) * atlas.pixelsPerMm);
    if row < 0 || row >= atlas.height || column < 0 || column >= atlas.width
        return
    end
    rows = atlas.rows;
    if isnumeric(rows)   % jsondecode gives a matrix when every row has as many runs
        runs = rows(row + 1, :);
    else
        runs = rows{row + 1};
    end
    ends = cumsum(runs(2:2:end));
    k = find(column < ends, 1);
    if isempty(k)
        return
    end
    index = runs(2 * k - 1);
    regions = atlas.regions;
    if iscell(regions)
        regions = [regions{:}];
    end
    match = find([regions.index] == index, 1);
    if ~isempty(match)
        label = char(regions(match).label);
    end
end
