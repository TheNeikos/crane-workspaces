use std::{collections::BTreeMap, path::PathBuf};

use cargo_metadata::{Metadata, MetadataCommand};
use clap::Parser;
use itertools::Itertools;
use pathdiff::diff_utf8_paths;
use serde::Serialize;

#[derive(Parser, Debug)]
#[clap(author, version, about)]
struct Args {
    manifest_path: PathBuf,
    target_platform: String,
}

fn main() {
    let args = Args::parse();
    let metadata = MetadataCommand::new()
        .manifest_path(args.manifest_path)
        .other_options(["--filter-platform".to_string(), args.target_platform])
        .exec()
        .unwrap();

    let wmi = WorkspaceMetadataInfo::from_metadata(metadata);

    println!("{}", toml::to_string(&wmi).unwrap());
}

#[derive(Debug, Serialize)]
struct WorkspaceMetadataInfo {
    workspace_member_info: BTreeMap<String, WorkspaceMemberMetadata>,
}

#[derive(Debug, Serialize)]
struct WorkspaceMemberMetadata {
    manifest_path: String,
    dependencies: BTreeMap<String, WorkspaceDependency>,
    workspace_path_dependencies: Vec<String>,
    workspace_deps: Vec<String>,
}

impl WorkspaceMemberMetadata {
    fn from_package(metadata: &Metadata, p: &cargo_metadata::Package) -> Self {
        let manifest_path = p
            .manifest_path
            .strip_prefix(&metadata.workspace_root)
            .unwrap()
            .to_string();

        let nodes = &metadata.resolve.as_ref().unwrap().nodes;

        let direct_dependencies = nodes
            .iter()
            .find(|n| n.id == p.id)
            .map(|np| {
                np.deps.iter().flat_map(|nd| {
                    nodes.iter().find(|n| n.id == nd.pkg).map(|n| {
                        let path: Option<String> = {
                            if metadata.workspace_members.contains(&n.id) {
                                let dep_package =
                                    metadata.packages.iter().find(|p| p.id == n.id).unwrap();
                                let traversal = diff_utf8_paths(
                                    &dep_package.manifest_path.parent().unwrap(),
                                    &p.manifest_path.parent().unwrap(),
                                )
                                .unwrap();
                                Some(traversal.to_string())
                            } else {
                                None
                            }
                        };
                        (
                            nd.name.clone(),
                            (
                                WorkspaceDependency {
                                    default_features: false,
                                    features: n.features.clone(),
                                    package: n
                                        .id
                                        .to_string()
                                        .split(' ')
                                        .next()
                                        .unwrap()
                                        .to_string(),
                                    version: n
                                        .id
                                        .to_string()
                                        .split(' ')
                                        .nth(1)
                                        .unwrap()
                                        .to_string(),
                                    path,
                                },
                                n.id.clone(),
                            ),
                        )
                    })
                })
            })
            .into_iter()
            .flatten()
            .collect::<BTreeMap<_, _>>();

        let dependencies = metadata
            .workspace_members
            .iter()
            .flat_map(|wm| {
                nodes
                    .iter()
                    .find(|n| n.id == *wm)
                    .into_iter()
                    .flat_map(|wn| &wn.dependencies)
                    .map(|wnp| nodes.iter().find(|n| n.id == *wnp))
            })
            .flatten()
            .filter(|n| !metadata.workspace_members.contains(&n.id))
            .filter(|n| direct_dependencies.iter().all(|(_, (_, id))| n.id != *id))
            .unique_by(|n| &n.id)
            .enumerate()
            .map(|(cnt, n)| {
                (
                    format!("workspace_dependency_{cnt}"),
                    WorkspaceDependency {
                        default_features: false,
                        features: n.features.clone(),
                        package: n.id.to_string().split(' ').next().unwrap().to_string(),
                        version: n.id.to_string().split(' ').nth(1).unwrap().to_string(),
                        path: None,
                    },
                )
            })
            .chain(
                direct_dependencies
                    .clone()
                    .into_iter()
                    .map(|(n, (v, _))| (n, v)),
            )
            .collect();

        let workspace_path_dependencies = direct_dependencies
            .iter()
            .filter(|(_, (_, n))| metadata.workspace_members.contains(n))
            .map(|(_, (_, n))| {
                let dep_package = metadata.packages.iter().find(|p| p.id == *n).unwrap();
                dep_package
                    .manifest_path
                    .strip_prefix(&metadata.workspace_root)
                    .unwrap()
                    .parent()
                    .unwrap()
                    .to_string()
            })
            .collect();

        let workspace_deps = direct_dependencies
            .iter()
            .filter(|(_, (_, n))| metadata.workspace_members.contains(n))
            .map(|(name, (_, _))| name.clone())
            .collect();

        WorkspaceMemberMetadata {
            manifest_path,
            dependencies,
            workspace_path_dependencies,
            workspace_deps,
        }
    }
}

#[derive(Debug, Serialize, Clone)]
struct WorkspaceDependency {
    #[serde(rename = "default-features")]
    default_features: bool,
    features: Vec<String>,
    package: String,
    version: String,
    path: Option<String>,
}

impl WorkspaceMetadataInfo {
    fn from_metadata(metadata: Metadata) -> Self {
        let workspace_member_info = metadata
            .workspace_packages()
            .iter()
            .map(|p| {
                (
                    p.id.to_string().split(' ').next().unwrap().to_string(),
                    WorkspaceMemberMetadata::from_package(&metadata, p),
                )
            })
            .collect();

        WorkspaceMetadataInfo {
            workspace_member_info,
        }
    }
}
