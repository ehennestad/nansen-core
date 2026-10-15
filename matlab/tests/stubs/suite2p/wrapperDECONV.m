function sp = wrapperDECONV(ops, F)
%wrapperDECONV Stub of Suite2P's: the traces (frames x ROIs) times sensorTau plus fs, so a test sees what it got
    assert(strcmp(ops.deconvType, 'OASIS') && ops.estimateNeuropil == 0, "not OASIS on the neuropil-corrected traces")
    sp = single(F * ops.sensorTau + ops.fs);
end
