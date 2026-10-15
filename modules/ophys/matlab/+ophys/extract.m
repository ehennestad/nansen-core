function result = extract(entity, options, context)
%extract Detect cells with EXTRACT, when it is on the path, and save them as ROIs with their traces
    if exist("extractor", "file") ~= 2 || exist("get_defaults", "file") ~= 2
        nansen.internal.throwError("dependency-missing", ...
            "ophys.extract needs EXTRACT on the MATLAB path: https://github.com/schnitzer-lab/EXTRACT-public")
    end
    stack = ophys.internal.loadStack(context, entity, options.stack);
    [height, width, frames] = size(stack);
    config = feval("get_defaults", []);
    config.avg_cell_radius = options.cellRadius;
    context.log("%s: running EXTRACT on %d frames", ophys.internal.entityName(entity), frames);
    output = feval("extractor", single(stack), config);
    weights = output.spatial_weights;
    rois = {};
    for i = 1:size(weights, 3)
        cell_ = weights(:, :, i);
        [rows, columns] = find(cell_ >= options.threshold * max(cell_, [], "all") & cell_ > 0);
        if ~isempty(rows)
            rois{end + 1} = ophys.internal.makeRoi(numel(rois) + 1, sortrows([rows, columns])); %#ok<AGROW>
        end
    end
    context.Project.save(entity, options.rois, struct("imageSize", [height, width], "rois", {rois}));
    ophys.internal.saveIf(context, entity, options.output, double(output.temporal_weights));
    result = struct("rois", numel(rois), "frames", frames);
end
