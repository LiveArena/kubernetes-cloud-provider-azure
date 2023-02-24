// /*
// Copyright The Kubernetes Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
// */

// Code generated by client-gen. DO NOT EDIT.
package diskclient

import (
	"context"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore"
	"github.com/Azure/azure-sdk-for-go/sdk/azcore/arm"
	armcompute "github.com/Azure/azure-sdk-for-go/sdk/resourcemanager/compute/armcompute/v4"

	"sigs.k8s.io/cloud-provider-azure/pkg/azureclients/v2/utils"
)

type Client struct {
	*armcompute.DisksClient
}

func New(subscriptionID string, credential azcore.TokenCredential, options *arm.ClientOptions) (Interface, error) {
	if options == nil {
		options = utils.GetDefaultOption("2022-03-02")
	}

	client, err := armcompute.NewDisksClient(subscriptionID, credential, options)
	if err != nil {
		return nil, err
	}
	return &Client{client}, nil
}

// Get gets the Disk
func (client *Client) Get(ctx context.Context, resourceGroupName string, resourceName string) (result *armcompute.Disk, rerr error) {
	var ops *armcompute.DisksClientGetOptions

	resp, err := client.DisksClient.Get(ctx, resourceGroupName, resourceName, ops)
	if err != nil {
		return nil, err
	}
	//handle statuscode
	return &resp.Disk, nil
}

// CreateOrUpdate creates or updates a Disk.
func (client *Client) CreateOrUpdate(ctx context.Context, resourceGroupName string, resourceName string, resource armcompute.Disk) (*armcompute.Disk, error) {
	resp, err := utils.NewPollerWrapper(client.DisksClient.BeginCreateOrUpdate(ctx, resourceGroupName, resourceName, resource, nil)).WaitforPollerResp(ctx)
	if err != nil {
		return nil, err
	}
	if resp != nil {
		return &resp.Disk, nil
	}
	return nil, nil
}

// Delete deletes a Disk by name.
func (client *Client) Delete(ctx context.Context, resourceGroupName string, resourceName string) error {
	_, err := utils.NewPollerWrapper(client.BeginDelete(ctx, resourceGroupName, resourceName, nil)).WaitforPollerResp(ctx)
	return err
}

// List gets a list of Disk in the resource group.
func (client *Client) List(ctx context.Context, resourceGroupName string) (result []*armcompute.Disk, rerr error) {
	pager := client.DisksClient.NewListByResourceGroupPager(resourceGroupName, nil)
	for pager.More() {
		nextResult, err := pager.NextPage(ctx)
		if err != nil {
			return nil, err
		}
		result = append(result, nextResult.Value...)
	}
	return result, nil
}
