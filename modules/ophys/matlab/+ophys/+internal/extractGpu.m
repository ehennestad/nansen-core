function use = extractGpu()
%extractGpu Whether EXTRACT can use a GPU here (it would try by default)
    use = false;
    try
        use = gpuDeviceCount("available") > 0;
    catch
    end
end
