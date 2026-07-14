// SPDX-License-Identifier: GPL-3.0-only
#pragma once

#include "BaseVersionList.h"
#include "java/JavaMetadata.h"
#include "meta/VersionList.h"

namespace Java {

struct GitHubMajorVersion : public BaseVersion {
    QString branch;
    QList<MetadataPtr> releases;

    QString descriptor() const override { return branch; }
    QString name() const override { return branch; }
    QString typeString() const override { return "GitHub"; }
};
using GitHubMajorVersionPtr = std::shared_ptr<GitHubMajorVersion>;

class GitHubMajorVersionList : public BaseVersionList {
    Q_OBJECT
   public:
    GitHubMajorVersionList(QString owner, QString repo, QObject* parent = nullptr);

    Task::Ptr getLoadTask(bool forceReload = false) override;
    bool isLoaded() override { return m_loaded; }
    const BaseVersion::Ptr at(int i) const override { return m_majors.at(i); }
    int count() const override { return m_majors.count(); }
    void sortVersions() override {}
    QVariant data(const QModelIndex& index, int role) const override;
    RoleList providesRoles() const override;

   protected slots:
    void updateListData(QList<BaseVersion::Ptr>) override {}

   private slots:
    void parseReleases();

   private:
    QString m_owner;
    QString m_repo;
    bool m_loaded = false;
    QList<GitHubMajorVersionPtr> m_majors;
    QByteArray* m_response = nullptr;
};

class GitHubReleaseVersionList : public BaseVersionList {
    Q_OBJECT
   public:
    explicit GitHubReleaseVersionList(GitHubMajorVersionPtr major, QObject* parent = nullptr);

    Task::Ptr getLoadTask(bool forceReload = false) override { return nullptr; }
    bool isLoaded() override { return true; }
    const BaseVersion::Ptr at(int i) const override { return m_major->releases.at(i); }
    int count() const override { return m_major->releases.count(); }
    void sortVersions() override {}
    QVariant data(const QModelIndex& index, int role) const override;
    RoleList providesRoles() const override;

   protected slots:
    void updateListData(QList<BaseVersion::Ptr>) override {}

   private:
    GitHubMajorVersionPtr m_major;
};

}  // namespace Java
