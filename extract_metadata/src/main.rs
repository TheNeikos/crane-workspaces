use std::{
    collections::{BTreeMap, HashMap},
    path::PathBuf,
    process::{Command, Output, Stdio},
};

use cargo_metadata::{Metadata, MetadataCommand, PackageId};
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

    let feature_sets = get_feature_sets();

    let wmi = WorkspaceMetadataInfo::from_metadata(metadata, feature_sets);

    println!("{}", toml::to_string(&wmi).unwrap());
}

/// cargo tree -f '{p}|{f}' --prefix none --target x86_64-unknown-linux-gnu

fn get_feature_sets() -> HashMap<(String, String), Vec<String>> {
    let mut cargo_tree = Command::new("cargo");
    cargo_tree.args([
        "tree",
        "-f",
        "{p}|{f}",
        "--prefix",
        "none",
        "--target",
        "x86_64-unknown-linux-gnu",
    ]);

    cargo_tree.stdin(Stdio::null());
    cargo_tree.stdout(Stdio::piped());
    cargo_tree.stderr(Stdio::piped());

    let Output { stdout, .. } = cargo_tree.output().unwrap();

    let raw_tree = String::from_utf8(stdout).unwrap();

    raw_tree
        .lines()
        .filter(|l| !(l.contains('*') || l.is_empty()))
        .map(|line| {
            let (krate, features) = line.split_once('|').unwrap();

            let mut krate = krate.split(' ');
            let (name, version) = krate.next_tuple().unwrap();

            let features = features
                .split(',')
                .filter(|f| !f.is_empty())
                .map(ToString::to_string)
                .collect();

            (
                (
                    name.to_string(),
                    version.trim_start_matches('v').to_string(),
                ),
                features,
            )
        })
        .collect()
}

#[derive(Debug, Serialize)]
struct WorkspaceMetadataInfo {
    workspace_member_info: BTreeMap<String, WorkspaceMemberMetadata>,
}

#[derive(Debug, Serialize)]
struct WorkspaceLocalDependency {
    name: String,
    path: String,
    #[serde(skip)]
    id: PackageId,
}

#[derive(Debug, Serialize)]
struct WorkspaceMemberMetadata {
    manifest_path: String,
    dependencies: BTreeMap<String, WorkspaceDependency>,
    features: BTreeMap<String, Vec<String>>,
    workspace_deps: Vec<WorkspaceLocalDependency>,
}

impl WorkspaceMemberMetadata {
    fn from_package(
        metadata: &Metadata,
        feature_sets: &HashMap<(String, String), Vec<String>>,
        package: &cargo_metadata::Package,
    ) -> Self {
        let manifest_path = package
            .manifest_path
            .strip_prefix(&metadata.workspace_root)
            .unwrap()
            .to_string();

        let package_for_id = |id: &cargo_metadata::PackageId| {
            metadata
                .resolve
                .as_ref()
                .unwrap()
                .nodes
                .iter()
                .find(|n| &n.id == id)
        };

        let is_normal_dep = |dep: &&cargo_metadata::NodeDep| {
            dep.dep_kinds
                .iter()
                .any(|d| matches!(d.kind, cargo_metadata::DependencyKind::Normal))
        };

        // All dependencies that are _directly_ referenced in the workspace
        let direct_workspace_dependencies: Vec<&cargo_metadata::Node> = metadata
            .workspace_packages()
            .into_iter()
            // Find the nodes associated with each workspace member
            .map(|p| package_for_id(&p.id).unwrap())
            // For all dependencies that are a normal dependency we get that that node
            .flat_map(|package_node| {
                package_node
                    .deps
                    .iter()
                    .filter(is_normal_dep)
                    .map(|dep| package_for_id(&dep.pkg).unwrap())
            })
            .unique_by(|n| n.id.clone())
            .collect_vec();

        // All dependencies referenced by the current package
        let direct_dependencies = package_for_id(&package.id)
            .unwrap()
            .deps
            .iter()
            .filter(is_normal_dep)
            .map(|nd| {
                let dep_node = package_for_id(&nd.pkg).unwrap();
                let path: Option<String> = {
                    if metadata.workspace_members.contains(&dep_node.id) {
                        let dep_package = metadata
                            .packages
                            .iter()
                            .find(|p| p.id == dep_node.id)
                            .unwrap();
                        let traversal = diff_utf8_paths(
                            &dep_package.manifest_path.parent().unwrap(),
                            &package.manifest_path.parent().unwrap(),
                        )
                        .unwrap();
                        Some(traversal.to_string())
                    } else {
                        None
                    }
                };
                let (name, version) = dep_node.id.repr.split(' ').next_tuple().unwrap();
                (
                    name.to_owned(),
                    WorkspaceDependency {
                        default_features: false,
                        features: feature_sets
                            .get(&(name.to_string(), version.to_string()))
                            .cloned()
                            .unwrap_or_default(),
                        optional: package
                            .dependencies
                            .iter()
                            .find(|d| d.name == name)
                            .map(|d| d.optional),
                        package: name.to_owned(),
                        version: version.to_owned(),
                        path,
                        id: dep_node.id.clone(),
                    },
                )
            })
            .collect::<BTreeMap<_, _>>();

        let remove_workspace_members =
            |n: &&&cargo_metadata::Node| !metadata.workspace_members.contains(&n.id);

        let ignore_direct_dependencies =
            |n: &&&cargo_metadata::Node| !direct_dependencies.iter().any(|(_, dd)| n.id == dd.id);

        let dependencies: BTreeMap<String, WorkspaceDependency> = direct_workspace_dependencies
            .iter()
            // We remove workspace members, as they should only be in _direct_ dependencies, they
            // are added above
            .filter(remove_workspace_members)
            // If its a direct dependency we also remove it, since they are already taken care of
            .filter(ignore_direct_dependencies)
            .enumerate()
            .map(|(cnt, n)| {
                let (name, version) = n.id.repr.split(' ').next_tuple().unwrap();
                (
                    format!("workspace_dependency_{cnt}"),
                    WorkspaceDependency {
                        default_features: false,
                        features: feature_sets
                            .get(&(name.to_string(), version.to_string()))
                            .cloned()
                            .unwrap_or_default(),
                        version: version.to_owned(),
                        optional: package
                            .dependencies
                            .iter()
                            .find(|d| d.name == name)
                            .map(|d| d.optional),
                        package: name.to_owned(),
                        path: None,
                        id: n.id.clone(),
                    },
                )
            })
            .chain(direct_dependencies.clone())
            .collect();

        // Gather all workspace dependencies, even transitive ones
        //
        // We need to know what kind of workspace members are needed to correctly this package.
        //
        // The recursive `collect_workspace_deps` will find those. Then, we iterate as deep as we
        // need to remove any dependency that is not enabled in the feature set.

        fn collect_workspace_deps<'a>(
            metadata: &'a Metadata,
            nodes: &'a [&'a cargo_metadata::Node],
            id: cargo_metadata::PackageId,
        ) -> Box<dyn Iterator<Item = WorkspaceLocalDependency> + 'a> {
            let is_workspace_member =
                |id: &cargo_metadata::PackageId| metadata.workspace_members.contains(&id);

            let workspace_deps = metadata
                .resolve
                .as_ref()
                .unwrap()
                .nodes
                .iter()
                .find(|n| n.id == id)
                .unwrap()
                // We have the node for the package
                .deps
                .iter()
                // We filter for _only_ workspace members
                .filter(move |d| is_workspace_member(&d.pkg))
                .map(|d| {
                    // For every package we find, we get its name, path etc...
                    let dep_package = metadata.packages.iter().find(|p| p.id == d.pkg).unwrap();
                    let path = dep_package
                        .manifest_path
                        .strip_prefix(&metadata.workspace_root)
                        .unwrap()
                        .parent()
                        .unwrap()
                        .to_string();
                    WorkspaceLocalDependency {
                        name: d.name.clone(),
                        id: d.pkg.clone(),
                        path,
                    }
                });

            // Since a workspace member could point to another one, we need to continue collecting
            Box::new(
                workspace_deps.clone().chain(
                    workspace_deps
                        .clone()
                        .flat_map(|n| collect_workspace_deps(metadata, nodes, n.id)),
                ),
            )
        }

        let workspace_deps =
            collect_workspace_deps(metadata, &direct_workspace_dependencies, package.id.clone())
                .unique_by(|d| d.id.clone())
                .collect();

        // Cleaning for features does the following:
        //
        // - Package foo depends on bar, both of which are workspace members
        // - This can cause problems later if the dependencies are _optional_ and NOT enabled.
        // - Since they show up as 'dependencies' but are not actually used, we don't want to have
        // to build `bar` just to build `foo`. But cargo will complain if `bar` does not exist as
        // intended.
        // - We thus construct a list of features that are 'safe'. Since features can chain with
        // eachother, we iterate until nothing changes.

        let mut features = package.features.clone();
        let mut prev_features = features.clone();

        features.retain(|_, v| {
            v.iter()
                .all(|d| direct_dependencies.contains_key(d) || package.features.contains_key(d))
        });

        while features != prev_features {
            eprintln!(
                "[{}] Features differ after cleaning. Doing another round...",
                package.name
            );
            prev_features = features.clone();
            features.retain(|k, v| {
                let has_dep = v.iter().all(|d| {
                    let direct = direct_dependencies.contains_key(d.trim_start_matches("dep:"));
                    let features = prev_features.contains_key(d);

                    let ret = direct || features;
                    eprintln!("[{}][{}] is_direct = {direct}, is_feature = {features}", package.name, d);
                    ret
                });

                eprintln!(
                    "[{}] Checked if {k} has all its enablings in dependencies/another feature: {has_dep}",
                    package.name
                );

                has_dep
            });
        }

        WorkspaceMemberMetadata {
            manifest_path,
            dependencies,
            features,
            workspace_deps,
        }
    }
}

fn is_some_false(opt: &Option<bool>) -> bool {
    opt.is_some_and(|b| !b)
}

#[derive(Debug, Serialize, Clone)]
struct WorkspaceDependency {
    #[serde(rename = "default-features")]
    default_features: bool,
    features: Vec<String>,
    #[serde(skip_serializing_if = "is_some_false")]
    optional: Option<bool>,
    package: String,
    version: String,
    path: Option<String>,
    #[serde(skip)]
    id: PackageId,
}

impl WorkspaceMetadataInfo {
    fn from_metadata(
        metadata: Metadata,
        feature_sets: HashMap<(String, String), Vec<String>>,
    ) -> Self {
        let workspace_member_info = metadata
            .workspace_packages()
            .iter()
            .map(|p| {
                (
                    p.id.to_string().split(' ').next().unwrap().to_string(),
                    WorkspaceMemberMetadata::from_package(&metadata, &feature_sets, p),
                )
            })
            .collect();

        WorkspaceMetadataInfo {
            workspace_member_info,
        }
    }
}
