// SPDX-License-Identifier: GPL-3.0-only
#include "GitHubJavaDownloader.h"

#include <QJsonArray>
#include <QRegularExpression>
#include <QJsonDocument>
#include <QJsonObject>

#include "Application.h"
#include "meta/VersionList.h"
#include "java/JavaVersion.h"
#include "net/Download.h"
#include "net/NetJob.h"

namespace Java {

// --- GitHubMajorVersionList: left panel, shows branches (e.g. "jbr25") ---

GitHubMajorVersionList::GitHubMajorVersionList(QString owner, QString repo, QObject* parent)
    : BaseVersionList(parent), m_owner(std::move(owner)), m_repo(std::move(repo))
{
}

Task::Ptr GitHubMajorVersionList::getLoadTask(bool forceReload)
{
    Q_UNUSED(forceReload)
    auto url = QString("https://api.github.com/repos/%1/%2/releases").arg(m_owner, m_repo);
    auto job = makeShared<NetJob>("GitHub Java Releases", APPLICATION->network());
    auto [action, response] = Net::Download::makeByteArray(QUrl(url));
    m_response = response;
    job->addNetAction(action);
    connect(job.get(), &NetJob::succeeded, this, &GitHubMajorVersionList::parseReleases);
    return job;
}

QVariant GitHubMajorVersionList::data(const QModelIndex& index, int role) const
{
    if (!index.isValid() || index.row() >= count())
        return {};
    const auto& ver = m_majors[index.row()];
    switch (role) {
        case SortRole:
            return -index.row();
        case VersionPointerRole:
            return QVariant::fromValue(std::static_pointer_cast<BaseVersion>(ver));
        case VersionIdRole:
        case VersionRole:
        case JavaMajorRole:
            return ver->branch;
        case RecommendedRole:
            return true;
        default:
            return {};
    }
}

BaseVersionList::RoleList GitHubMajorVersionList::providesRoles() const
{
    return { JavaMajorRole, RecommendedRole, VersionPointerRole };
}

void GitHubMajorVersionList::parseReleases()
{
    beginResetModel();
    m_majors.clear();

    QMap<QString, GitHubMajorVersionPtr> majorMap;

    for (const auto& releaseVal : QJsonDocument::fromJson(*m_response).array()) {
        auto release = releaseVal.toObject();
        auto tagName = release["tag_name"].toString();
        auto branch = release["target_commitish"].toString();
        auto publishedAt = release["published_at"].toString();

        for (const auto& assetVal : release["assets"].toArray()) {
            auto asset = assetVal.toObject();
            if (!asset["name"].toString().endsWith(".tar.gz"))
                continue;

            auto meta = std::make_shared<Metadata>();
            meta->m_name = tagName;
            meta->vendor = m_owner;
            meta->url = asset["browser_download_url"].toString();
            meta->releaseTime = QDateTime::fromString(publishedAt, Qt::ISODate);
            meta->downloadType = DownloadType::Archive;
            meta->packageType = "jdk";
            meta->runtimeOS = "mac-os-x64";
            meta->version = JavaVersion(tagName);

            if (!majorMap.contains(branch)) {
                auto mv = std::make_shared<GitHubMajorVersion>();
                // Parse branch like "jbr25" → "Java 25"
                QString majorNum = branch;
                majorNum.remove(QRegularExpression("[^0-9]"));
                mv->branch = majorNum.isEmpty() ? branch : QString("Java %1").arg(majorNum);
                majorMap[branch] = mv;
            }
            majorMap[branch]->releases.append(meta);
        }
    }

    m_majors = majorMap.values();
    m_loaded = true;
    endResetModel();
}

// --- GitHubReleaseVersionList: right panel, shows releases for selected branch ---

GitHubReleaseVersionList::GitHubReleaseVersionList(GitHubMajorVersionPtr major, QObject* parent)
    : BaseVersionList(parent), m_major(std::move(major))
{
}

QVariant GitHubReleaseVersionList::data(const QModelIndex& index, int role) const
{
    if (!index.isValid() || index.row() >= count())
        return {};
    const auto& ver = m_major->releases[index.row()];
    switch (role) {
        case SortRole:
            return -index.row();
        case VersionPointerRole:
            return QVariant::fromValue(std::static_pointer_cast<BaseVersion>(ver));
        case VersionIdRole:
            return ver->descriptor();
        case VersionRole:
            return ver->version.toString();
        case RecommendedRole:
            return index.row() == 0;
        case JavaNameRole:
            return ver->name();
        case TypeRole:
            return ver->packageType;
        case Meta::VersionList::TimeRole:
            return ver->releaseTime;
        default:
            return {};
    }
}

BaseVersionList::RoleList GitHubReleaseVersionList::providesRoles() const
{
    return { VersionPointerRole, VersionIdRole, VersionRole, RecommendedRole, JavaNameRole, TypeRole, Meta::VersionList::TimeRole };
}

}  // namespace Java
