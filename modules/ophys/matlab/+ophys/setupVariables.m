function result = setupVariables(project, options, context)
%setupVariables Add the data variables the ophys methods use, and the imaging and image statistics columns
    entityType = string(options.entityType);
    project.entityType(entityType);
    have = string.empty;
    for variable = reshape(project.dataVariables(), 1, [])
        have(end + 1) = variable.Name; %#ok<AGROW>
    end
    variables = {
        "TwoPhotonSeries_Corrected", "Motion-corrected stack", "two_photon_series_corrected.npy", "npy", "ImageStack"
        "TwoPhotonSeries_Downsampled", "Downsampled stack", "two_photon_series_downsampled.npy", "npy", "ImageStack"
        "MotionCorrectionShifts", "Motion correction shifts", "motion_correction_shifts.npy", "npy", "Array"
        "FovAverageProjection", "Average projection", "fov_average_projection.npy", "npy", "Image"
        "FovMaximumProjection", "Maximum projection", "fov_maximum_projection.npy", "npy", "Image"
        "RoiArray", "ROIs", "roi_array.json", "json", "RoiArray"
        "RoiSignals_MeanF", "ROI signals", "roi_signals_mean_f.npy", "npy", "RoiSignals"
        "RoiSignals_NeuropilF", "Neuropil signals", "roi_signals_neuropil_f.npy", "npy", "RoiSignals"
        "RoiSignals_Dff", "ROI ΔF/F", "roi_signals_dff.npy", "npy", "RoiSignals"
        "RoiSignals_Deconvolved", "Deconvolved spikes", "roi_signals_deconvolved.npy", "npy", "RoiSignals"
        "RoiSignals_Denoised", "Denoised calcium", "roi_signals_denoised.npy", "npy", "RoiSignals"
        "TwoPhotonSeries_Denoised", "Denoised stack", "two_photon_series_denoised.npy", "npy", "ImageStack"};
    documents = {};
    if strlength(string(options.rawFilePattern)) > 0
        documents{end + 1} = struct("schemaType", "nansen.dataVariable", "schemaVersion", "0.1.0", ...
            "name", "TwoPhotonSeries_Original", "title", "Raw recording", "entityType", entityType, ...
            "dataLocation", string(options.rawDataLocation), "filePattern", string(options.rawFilePattern), ...
            "fileAdapter", string(options.rawFileAdapter), "dataType", "ImageStack");
    end
    for i = 1:size(variables, 1)
        document = struct("schemaType", "nansen.dataVariable", "schemaVersion", "0.1.0", ...
            "name", variables{i, 1}, "title", variables{i, 2}, "entityType", entityType, ...
            "dataLocation", string(options.dataLocation));
        if strlength(string(options.subfolder)) > 0
            document.subfolder = string(options.subfolder);
        end
        document.fileName = variables{i, 3};
        document.fileAdapter = variables{i, 4};
        document.dataType = variables{i, 5};
        documents{end + 1} = document; %#ok<AGROW>
    end
    created = {};
    existing = {};
    for i = 1:numel(documents)
        name = char(documents{i}.name);
        if any(have == name)
            existing{end + 1} = name; %#ok<AGROW>
        else
            project.addDataVariable(documents{i});
            created{end + 1} = name; %#ok<AGROW>
        end
    end
    columns = {};
    if options.addColumns
        owners = repmat(entityType, 1, 4);
        wanted = ["ophys.imaging", "ophys.image_stats", "ophys.fov_position", "ophys.fov_region"];
        if any(project.EntityTypes == string(options.subjectType))
            owners(end + 1) = string(options.subjectType);
            wanted(end + 1) = "ophys.cranial_window";
        end
        for i = 1:numel(wanted)
            entry = project.entityType(owners(i));
            listed = string(nansen.internal.asCellstr(nansen.internal.getField(entry, "fragments", {})));
            if ~any(listed == wanted(i))
                project.attachFragment(owners(i), wanted(i));
                columns{end + 1} = char(wanted(i)); %#ok<AGROW>
            end
        end
    end
    context.log("added %d data variables to %s", numel(created), entityType);
    result = struct("created", {created}, "existing", {existing}, "fragments", {columns});
end
