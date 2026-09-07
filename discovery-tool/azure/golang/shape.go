package main

// Shaping ARM resources into the output record.
//
// Every shaper reads the raw ARM JSON and must produce exactly the field names
// and values the Python and bash implementations produce — the parity harness
// diffs all three line for line. Fields absent from a response stay nil rather
// than being dropped, so a record has the same keys whichever provider version
// answered and a consumer can diff two runs field by field.

func shapeDisk(d map[string]any) map[string]any {
	props := asObject(d["properties"])
	return map[string]any{
		"id":                 d["id"],
		"name":               d["name"],
		"resource_group":     resourceGroupOf(d["id"]),
		"location":           d["location"],
		"zones":              listOf(d, "zones"),
		"sku_name":           dig(d, "sku", "name"),
		"sku_tier":           dig(d, "sku", "tier"),
		"size_gb":            props["diskSizeGB"],
		"state":              props["diskState"],
		"provisioning_state": props["provisioningState"],
		"iops":               props["diskIOPSReadWrite"],
		"mbps":               props["diskMBpsReadWrite"],
		"performance_tier":   props["tier"],
		"bursting_enabled":   props["burstingEnabled"],
		"os_type":            props["osType"],
		"encryption_type":    dig(props, "encryption", "type"),
		"create_option":      dig(props, "creationData", "createOption"),
		"source_resource_id": dig(props, "creationData", "sourceResourceId"),
		"created_at":         props["timeCreated"],
		// managedBy is the VM the disk is attached to, empty when unattached —
		// the distinction Datafy is being asked to scope, so it is lifted out of
		// the id rather than left for the reader to parse.
		"attached_to":      d["managedBy"],
		"attached_to_name": nameOf(d["managedBy"]),
		"tags":             tagsOf(d),
	}
}

// powerState reports the VM's run state, from the instance view.
//
// Reported separately from provisioningState: a deallocated VM is still
// "Succeeded" provisioning-wise, and a stopped VM that still pays for its disks
// is exactly what a scoping run needs to see.
func powerState(props map[string]any) any {
	for _, raw := range asArray(dig(props, "instanceView", "statuses")) {
		status := asObject(raw)
		code, _ := status["code"].(string)
		if len(code) > len("PowerState/") && code[:len("PowerState/")] == "PowerState/" {
			return code[len("PowerState/"):]
		}
	}
	return nil
}

func osDiskOf(props map[string]any) any {
	osDisk := asObject(dig(props, "storageProfile", "osDisk"))
	if len(osDisk) == 0 {
		return nil
	}
	return map[string]any{
		"name":                 osDisk["name"],
		"os_type":              osDisk["osType"],
		"size_gb":              osDisk["diskSizeGB"],
		"caching":              osDisk["caching"],
		"create_option":        osDisk["createOption"],
		"managed_disk_id":      dig(osDisk, "managedDisk", "id"),
		"storage_account_type": dig(osDisk, "managedDisk", "storageAccountType"),
		// Set only on the unmanaged (page-blob) disks that predate Managed
		// Disks. Present in the record because a tenant still running them is a
		// material scoping finding, not an empty field.
		"vhd_uri": dig(osDisk, "vhd", "uri"),
	}
}

func dataDisksOf(props map[string]any) []any {
	out := []any{}
	for _, raw := range asArray(dig(props, "storageProfile", "dataDisks")) {
		dd := asObject(raw)
		out = append(out, map[string]any{
			"lun":                  dd["lun"],
			"name":                 dd["name"],
			"size_gb":              dd["diskSizeGB"],
			"caching":              dd["caching"],
			"create_option":        dd["createOption"],
			"managed_disk_id":      dig(dd, "managedDisk", "id"),
			"storage_account_type": dig(dd, "managedDisk", "storageAccountType"),
			"vhd_uri":              dig(dd, "vhd", "uri"),
		})
	}
	return out
}

func imageReferenceOf(props map[string]any) any {
	ref := asObject(dig(props, "storageProfile", "imageReference"))
	if len(ref) == 0 {
		return nil
	}
	return map[string]any{
		"publisher":                  ref["publisher"],
		"offer":                      ref["offer"],
		"sku":                        ref["sku"],
		"version":                    ref["version"],
		"exact_version":              ref["exactVersion"],
		"id":                         ref["id"],
		"shared_gallery_image_id":    ref["sharedGalleryImageId"],
		"community_gallery_image_id": ref["communityGalleryImageId"],
	}
}

func shapeVM(v map[string]any) map[string]any {
	props := asObject(v["properties"])
	return map[string]any{
		"id":                  v["id"],
		"name":                v["name"],
		"resource_group":      resourceGroupOf(v["id"]),
		"location":            v["location"],
		"zones":               listOf(v, "zones"),
		"vm_id":               props["vmId"],
		"vm_size":             dig(props, "hardwareProfile", "vmSize"),
		"provisioning_state":  props["provisioningState"],
		"power_state":         powerState(props),
		"os_type":             dig(props, "storageProfile", "osDisk", "osType"),
		"license_type":        props["licenseType"],
		"priority":            props["priority"],
		"eviction_policy":     props["evictionPolicy"],
		"availability_set_id": dig(props, "availabilitySet", "id"),
		"scale_set_id":        dig(props, "virtualMachineScaleSet", "id"),
		"os_disk":             osDiskOf(props),
		"data_disks":          dataDisksOf(props),
		"image_reference":     imageReferenceOf(props),
		"tags":                tagsOf(v),
	}
}

// shapeScaleSet reports a VM scale set.
//
// Collected because a Uniform-orchestration scale set's member VMs do not
// appear in the subscription's virtualMachines list at all — only their disks
// do. Without this, a tenant that runs most of its fleet in scale sets would
// show disks attached to machines the file never mentions.
func shapeScaleSet(s map[string]any) map[string]any {
	props := asObject(s["properties"])
	profile := asObject(dig(props, "virtualMachineProfile", "storageProfile"))

	dataDisks := []any{}
	for _, raw := range asArray(profile["dataDisks"]) {
		dd := asObject(raw)
		dataDisks = append(dataDisks, map[string]any{
			"lun":                  dd["lun"],
			"size_gb":              dd["diskSizeGB"],
			"caching":              dd["caching"],
			"storage_account_type": dig(dd, "managedDisk", "storageAccountType"),
		})
	}

	return map[string]any{
		"id":                           s["id"],
		"name":                         s["name"],
		"resource_group":               resourceGroupOf(s["id"]),
		"location":                     s["location"],
		"zones":                        listOf(s, "zones"),
		"sku_name":                     dig(s, "sku", "name"),
		"sku_tier":                     dig(s, "sku", "tier"),
		"capacity":                     dig(s, "sku", "capacity"),
		"orchestration_mode":           props["orchestrationMode"],
		"provisioning_state":           props["provisioningState"],
		"os_type":                      dig(profile, "osDisk", "osType"),
		"os_disk_size_gb":              dig(profile, "osDisk", "diskSizeGB"),
		"os_disk_storage_account_type": dig(profile, "osDisk", "managedDisk", "storageAccountType"),
		"data_disks":                   dataDisks,
		"tags":                         tagsOf(s),
	}
}

func shapeSnapshot(s map[string]any) map[string]any {
	props := asObject(s["properties"])
	return map[string]any{
		"id":                 s["id"],
		"name":               s["name"],
		"resource_group":     resourceGroupOf(s["id"]),
		"location":           s["location"],
		"sku_name":           dig(s, "sku", "name"),
		"sku_tier":           dig(s, "sku", "tier"),
		"size_gb":            props["diskSizeGB"],
		"state":              props["diskState"],
		"incremental":        props["incremental"],
		"os_type":            props["osType"],
		"encryption_type":    dig(props, "encryption", "type"),
		"create_option":      dig(props, "creationData", "createOption"),
		"source_resource_id": dig(props, "creationData", "sourceResourceId"),
		// The disk this snapshot came from, which is what makes a snapshot
		// attributable to the volume it is protecting.
		"source_disk_name": nameOf(dig(props, "creationData", "sourceResourceId")),
		"created_at":       props["timeCreated"],
		"tags":             tagsOf(s),
	}
}

func shapeImage(i map[string]any) map[string]any {
	props := asObject(i["properties"])
	osDisk := asObject(dig(props, "storageProfile", "osDisk"))
	return map[string]any{
		"id":                        i["id"],
		"name":                      i["name"],
		"resource_group":            resourceGroupOf(i["id"]),
		"location":                  i["location"],
		"provisioning_state":        props["provisioningState"],
		"hyper_v_generation":        props["hyperVGeneration"],
		"source_virtual_machine_id": dig(props, "sourceVirtualMachine", "id"),
		"os_type":                   osDisk["osType"],
		"os_state":                  osDisk["osState"],
		"os_disk_size_gb":           osDisk["diskSizeGB"],
		"data_disk_count":           len(asArray(dig(props, "storageProfile", "dataDisks"))),
		"tags":                      tagsOf(i),
	}
}

func shapeVault(v map[string]any, vaultType string) map[string]any {
	return map[string]any{
		"id":             v["id"],
		"name":           v["name"],
		"resource_group": resourceGroupOf(v["id"]),
		"location":       v["location"],
		"vault_type":     vaultType,
		"sku_name":       dig(v, "sku", "name"),
		"tags":           tagsOf(v),
	}
}

// shapePolicy reports a backup policy, kept alongside the vault it belongs to.
//
// The two vault families are reported in one list with vault_type telling them
// apart: Recovery Services vaults hold the classic VM backup policies, and Data
// Protection backup vaults hold the newer per-disk ones. Which family a
// customer uses is itself a scoping finding, so neither is folded into the
// other.
func shapePolicy(p, vault map[string]any, vaultType string) map[string]any {
	props := asObject(p["properties"])
	policyType := props["policyType"]
	if policyType == nil {
		policyType = props["objectType"]
	}
	return map[string]any{
		"id":                     p["id"],
		"name":                   p["name"],
		"vault_id":               vault["id"],
		"vault_name":             vault["name"],
		"vault_type":             vaultType,
		"resource_group":         resourceGroupOf(p["id"]),
		"backup_management_type": props["backupManagementType"],
		"datasource_types":       props["datasourceTypes"],
		"policy_type":            policyType,
		"protected_items_count":  props["protectedItemsCount"],
	}
}
