import { redirect } from 'next/navigation';

/** /dashboard/property-deals → Today. */
export default function PropertyDealsHome() {
  redirect('/dashboard/property-deals/today');
}
