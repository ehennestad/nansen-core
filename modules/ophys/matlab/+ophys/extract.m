function result = extract(entity, options, context)
%extract Detect cells with EXTRACT, when it is on the path, and save them as ROIs with their traces
    if exist("extractor", "file") ~= 2 || exist("get_defaults", "file") ~= 2
        nansen.internal.throwError("dependency-missing", ...
            "ophys.extract needs EXTRACT on the MATLAB path: https://github.com/schnitzer-lab/EXTRACT-public")
    end
    stack = ophys.internal.loadStack(context, entity, options.stack);
    [height, width, frames] = size(stack);
    config = struct("avg_cell_radius", options.cellRadius, "use_sparse_arrays", 0, "verbose", 1, ...
        "num_partitions_x", 1, "num_partitions_y", 1, "use_gpu", ophys.internal.extractGpu(), ...
        "thresholds", struct("T_min_snr", double(options.minSnr)));
    config = feval("get_defaults", config);
    context.log("%s: running EXTRACT on %d frames", ophys.internal.entityName(entity), frames);
    output = feval("extractor", single(stack), config);
    context.log("%s: EXTRACT kept %d cells", ophys.internal.entityName(entity), size(output.spatial_weights, 3));
    weights = full(double(output.spatial_weights));
    rois = {};
    kept = [];
    for i = 1:size(weights, 3)
        cell_ = weights(:, :, i);
        [peak, at] = max(cell_, [], "all");
        if peak <= 0
            continue
        end
        % the 8-connected area around the peak, as dev's enforceSingleSegment: a cell's weights can have
        % faint patches elsewhere that would move its centre
        [peakRow, peakColumn] = ind2sub([height, width], at);
        areas = ophys.internal.components(cell_ >= options.threshold * peak, 8);
        for k = 1:numel(areas)
            if any(areas{k}(:, 1) == peakRow & areas{k}(:, 2) == peakColumn)
                rois{end + 1} = ophys.internal.makeRoi(numel(rois) + 1, sortrows(areas{k})); %#ok<AGROW>
                kept(end + 1) = i; %#ok<AGROW>
                break
            end
        end
    end
    context.Project.save(entity, options.rois, struct("imageSize", [height, width], "rois", {rois}));
    ophys.internal.saveIf(context, entity, options.output, double(output.temporal_weights(:, kept)));
    result = struct("rois", numel(rois), "frames", frames);
end
