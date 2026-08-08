import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import { headers } from "next/headers";
import "./globals.css";

const geistSans = Geist({ variable: "--font-geist-sans", subsets: ["latin"] });
const geistMono = Geist_Mono({ variable: "--font-geist-mono", subsets: ["latin"] });

export async function generateMetadata(): Promise<Metadata> {
  const requestHeaders = await headers();
  const host = requestHeaders.get("x-forwarded-host") ?? requestHeaders.get("host") ?? "localhost:3000";
  const protocol = requestHeaders.get("x-forwarded-proto") ?? (host.startsWith("localhost") ? "http" : "https");
  const metadataBase = new URL(`${protocol}://${host}`);

  return {
    metadataBase,
    title: "從 MacBook 到 GitOps｜3-node K8s 完整實戰 Lab",
    description: "給後端工程師的 VMware、Terraform、Ansible、containerd、kubeadm、Go API、Argo CD 與監控完整互動教學。",
    icons: { icon: "/og.png" },
    openGraph: {
      type: "website",
      locale: "zh_TW",
      title: "MAC → VMWARE → K8S → GITOPS",
      description: "三台 VM，一條可重建的平台鏈。",
      images: [{ url: "/og.png", width: 1731, height: 909, alt: "從 MacBook 到三節點 Kubernetes GitOps 的平台鏈" }],
    },
    twitter: { card: "summary_large_image", title: "MAC → VMWARE → K8S → GITOPS", description: "三台 VM，一條可重建的平台鏈。", images: ["/og.png"] },
  };
}

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="zh-Hant">
      <body className={`${geistSans.variable} ${geistMono.variable}`}>{children}</body>
    </html>
  );
}

