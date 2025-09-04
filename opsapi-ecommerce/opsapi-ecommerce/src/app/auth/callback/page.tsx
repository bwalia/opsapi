"use client";
import { useEffect, useState } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { useAuth } from "@/contexts/AuthContext";

export default function AuthCallback() {
  const [status, setStatus] = useState<'loading' | 'success' | 'error'>('loading');
  const [error, setError] = useState('');
  const router = useRouter();
  const searchParams = useSearchParams();
  const { handleOAuthCallback } = useAuth();

  useEffect(() => {
    const processCallback = async () => {
      try {
        const token = searchParams.get('token');
        const redirectPath = searchParams.get('redirect');

        if (!token) {
          throw new Error('No authentication token received');
        }

        const user = await handleOAuthCallback(token);
        setStatus('success');

        // Redirect based on user role and redirect parameter
        setTimeout(() => {
          if (user?.role === 'seller') {
            router.push('/seller/stores');
          } else {
            router.push(redirectPath || '/');
          }
        }, 1500);

      } catch (err: any) {
        console.error('OAuth callback error:', err);
        setError(err.message || 'Authentication failed');
        setStatus('error');
        
        // Redirect to login page after error
        setTimeout(() => {
          router.push('/login');
        }, 3000);
      }
    };

    processCallback();
  }, [searchParams, handleOAuthCallback, router]);

  return (
    <div className="min-h-screen bg-gray-50 flex items-center justify-center">
      <div className="max-w-md w-full mx-4">
        <div className="card">
          <div className="card-body text-center">
            {status === 'loading' && (
              <>
                <div className="animate-spin rounded-full h-12 w-12 border-b-2 border-[#fe004d] mx-auto mb-4"></div>
                <h2 className="text-lg font-semibold text-gray-900 mb-2">
                  Completing Sign In...
                </h2>
                <p className="text-gray-600 text-sm">
                  Please wait while we set up your account
                </p>
              </>
            )}

            {status === 'success' && (
              <>
                <div className="w-12 h-12 bg-green-100 rounded-full flex items-center justify-center mx-auto mb-4">
                  <svg className="w-6 h-6 text-green-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M5 13l4 4L19 7" />
                  </svg>
                </div>
                <h2 className="text-lg font-semibold text-gray-900 mb-2">
                  Sign In Successful!
                </h2>
                <p className="text-gray-600 text-sm">
                  Redirecting you to your dashboard...
                </p>
              </>
            )}

            {status === 'error' && (
              <>
                <div className="w-12 h-12 bg-red-100 rounded-full flex items-center justify-center mx-auto mb-4">
                  <svg className="w-6 h-6 text-red-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M6 18L18 6M6 6l12 12" />
                  </svg>
                </div>
                <h2 className="text-lg font-semibold text-gray-900 mb-2">
                  Sign In Failed
                </h2>
                <p className="text-red-600 text-sm mb-4">
                  {error}
                </p>
                <p className="text-gray-600 text-sm">
                  Redirecting to login page...
                </p>
              </>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}